// process_windows.c
#ifdef _WIN32

#include "process_windows.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

// Windows-specific includes
#include <windows.h>

// Helper to check if string needs quoting
static int needs_quoting(const char* str) {
    if (strchr(str, ' ') != NULL || strchr(str, '\t') != NULL ||
        strchr(str, '\n') != NULL || strchr(str, '\v') != NULL ||
        *str == '\0') {
        return 1;
    }
    return 0;
}

// Helper to quote argument (Windows command line quoting)
static void quote_argument(char* dest, const char* src) {
    int i = 0, j = 0;
    
    dest[j++] = '"';
    
    while (src[i] != '\0') {
        int backslashes = 0;
        
        // Count consecutive backslashes
        while (src[i] == '\\') {
            i++;
            backslashes++;
        }
        
        if (src[i] == '\0') {
            // Escape all backslashes before closing quote
            for (int k = 0; k < backslashes * 2; k++) {
                dest[j++] = '\\';
            }
            break;
        } else if (src[i] == '"') {
            // Escape all backslashes and the quote
            for (int k = 0; k < backslashes * 2; k++) {
                dest[j++] = '\\';
            }
            dest[j++] = '\\';
            dest[j++] = '"';
            i++;
        } else {
            // Just copy the backslashes
            for (int k = 0; k < backslashes; k++) {
                dest[j++] = '\\';
            }
            dest[j++] = src[i];
            i++;
        }
    }
    
    dest[j++] = '"';
    dest[j] = '\0';
}

// Better command line creation for Windows
static char* create_command_line_ex(const char* cmd, char** args) {
    // First calculate total length
    int length = 0;
    
    // Command
    if (needs_quoting(cmd)) {
        length += strlen(cmd) * 2 + 10; // Worst case: all chars need escaping
    } else {
        length += strlen(cmd) + 1;
    }
    
    // Arguments
    for (int i = 0; args[i] != NULL; i++) {
        length++; // Space separator
        if (needs_quoting(args[i])) {
            length += strlen(args[i]) * 2 + 10;
        } else {
            length += strlen(args[i]) + 1;
        }
    }
    
    // Allocate buffer
    char* cmdline = malloc(length + 1);
    if (!cmdline) return NULL;
    
    int pos = 0;
    
    // Add command
    if (needs_quoting(cmd)) {
        quote_argument(cmdline + pos, cmd);
        pos += strlen(cmdline + pos);
    } else {
        strcpy(cmdline + pos, cmd);
        pos += strlen(cmd);
    }
    
    // Add arguments
    for (int i = 0; args[i] != NULL; i++) {
        cmdline[pos++] = ' ';
        if (needs_quoting(args[i])) {
            quote_argument(cmdline + pos, args[i]);
            pos += strlen(cmdline + pos);
        } else {
            strcpy(cmdline + pos, args[i]);
            pos += strlen(args[i]);
        }
    }
    
    cmdline[pos] = '\0';
    return cmdline;
}

// Helper function to read from a handle with timeout
static int read_from_handle(HANDLE h, char* buffer, int buffer_size, int timeout_ms) {
    if (h == INVALID_HANDLE_VALUE) return -1;
    
    DWORD bytesRead = 0;
    OVERLAPPED overlapped = {0};
    HANDLE hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    
    if (!hEvent) return -1;
    
    overlapped.hEvent = hEvent;
    
    // Start asynchronous read
    BOOL success = ReadFile(h, buffer, buffer_size - 1, &bytesRead, &overlapped);
    
    if (!success) {
        DWORD err = GetLastError();
        if (err == ERROR_IO_PENDING) {
            // Wait for read to complete
            DWORD waitResult = WaitForSingleObject(hEvent, timeout_ms);
            if (waitResult == WAIT_OBJECT_0) {
                // Read completed, get result
                if (!GetOverlappedResult(h, &overlapped, &bytesRead, FALSE)) {
                    bytesRead = 0;
                }
            } else {
                // Timeout or error
                CancelIo(h);
                bytesRead = 0;
            }
        } else if (err == ERROR_BROKEN_PIPE) {
            // Pipe was closed
            bytesRead = 0;
        } else {
            // Other error
            bytesRead = -1;
        }
    }
    
    if (hEvent != INVALID_HANDLE_VALUE) {
        CloseHandle(hEvent);
    }
    
    if (bytesRead > 0) {
        buffer[bytesRead] = '\0';  // Null-terminate
    } else if (bytesRead == 0) {
        // EOF or timeout
        return 0;
    }
    
    return (int)bytesRead;
}

ProcessHandle* start_process(const char* cmd, char** args) {
    SECURITY_ATTRIBUTES saAttr;
    HANDLE hChildStdinRd = INVALID_HANDLE_VALUE;
    HANDLE hChildStdinWr = INVALID_HANDLE_VALUE;
    HANDLE hChildStdoutRd = INVALID_HANDLE_VALUE;
    HANDLE hChildStdoutWr = INVALID_HANDLE_VALUE;
    HANDLE hChildStderrRd = INVALID_HANDLE_VALUE;
    HANDLE hChildStderrWr = INVALID_HANDLE_VALUE;
    PROCESS_INFORMATION piProcInfo;
    STARTUPINFO siStartInfo;
    BOOL bSuccess;
    
    // Set up security attributes
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES);
    saAttr.bInheritHandle = TRUE;
    saAttr.lpSecurityDescriptor = NULL;
    
    // Create pipes for stdin
    if (!CreatePipe(&hChildStdinRd, &hChildStdinWr, &saAttr, 0)) {
        return NULL;
    }
    
    // Create pipes for stdout
    if (!CreatePipe(&hChildStdoutRd, &hChildStdoutWr, &saAttr, 0)) {
        CloseHandle(hChildStdinRd);
        CloseHandle(hChildStdinWr);
        return NULL;
    }
    
    // Create pipes for stderr
    if (!CreatePipe(&hChildStderrRd, &hChildStderrWr, &saAttr, 0)) {
        CloseHandle(hChildStdinRd);
        CloseHandle(hChildStdinWr);
        CloseHandle(hChildStdoutRd);
        CloseHandle(hChildStdoutWr);
        return NULL;
    }
    
    // Ensure the write handle to stdin and read handles from stdout/stderr
    // are not inherited by the child process
    if (!SetHandleInformation(hChildStdinWr, HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(hChildStdoutRd, HANDLE_FLAG_INHERIT, 0) ||
        !SetHandleInformation(hChildStderrRd, HANDLE_FLAG_INHERIT, 0)) {
        CloseHandle(hChildStdinRd);
        CloseHandle(hChildStdinWr);
        CloseHandle(hChildStdoutRd);
        CloseHandle(hChildStdoutWr);
        CloseHandle(hChildStderrRd);
        CloseHandle(hChildStderrWr);
        return NULL;
    }
    
    // Set up startup info
    ZeroMemory(&piProcInfo, sizeof(PROCESS_INFORMATION));
    ZeroMemory(&siStartInfo, sizeof(STARTUPINFO));
    siStartInfo.cb = sizeof(STARTUPINFO);
    siStartInfo.hStdError = hChildStderrWr;
    siStartInfo.hStdOutput = hChildStdoutWr;
    siStartInfo.hStdInput = hChildStdinRd;
    siStartInfo.dwFlags |= STARTF_USESTDHANDLES;
    
    // Create command line
    char* cmdline = create_command_line_ex(cmd, args);
    if (!cmdline) {
        CloseHandle(hChildStdinRd);
        CloseHandle(hChildStdinWr);
        CloseHandle(hChildStdoutRd);
        CloseHandle(hChildStdoutWr);
        CloseHandle(hChildStderrRd);
        CloseHandle(hChildStderrWr);
        return NULL;
    }
    
    // Create the child process
    bSuccess = CreateProcess(
        NULL,           // application name (use command line)
        cmdline,        // command line
        NULL,           // process security attributes
        NULL,           // thread security attributes
        TRUE,           // handles are inherited
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, // creation flags
        NULL,           // use parent's environment
        NULL,           // use parent's current directory
        &siStartInfo,   // startup info
        &piProcInfo     // process info
    );
    
    free(cmdline);
    
    // Close handles we don't need in parent
    CloseHandle(hChildStdinRd);
    CloseHandle(hChildStdoutWr);
    CloseHandle(hChildStderrWr);
    
    if (!bSuccess) {
        CloseHandle(hChildStdinWr);
        CloseHandle(hChildStdoutRd);
        CloseHandle(hChildStderrRd);
        return NULL;
    }
    
    // Close thread handle (we only need process handle)
    CloseHandle(piProcInfo.hThread);
    
    // Allocate and initialize process handle
    ProcessHandle* handle = malloc(sizeof(ProcessHandle));
    if (!handle) {
        CloseHandle(hChildStdinWr);
        CloseHandle(hChildStdoutRd);
        CloseHandle(hChildStderrRd);
        CloseHandle(piProcInfo.hProcess);
        return NULL;
    }
    
    handle->pid = piProcInfo.dwProcessId;
    handle->hProcess = piProcInfo.hProcess;
    handle->input_fd = hChildStdinWr;
    handle->output_fd = hChildStdoutRd;
    handle->error_fd = hChildStderrRd;
    
    return handle;
}

void close_process(ProcessHandle* handle) {
    if (handle) {
        // Close pipe handles
        if (handle->input_fd != INVALID_HANDLE_VALUE) {
            CloseHandle(handle->input_fd);
        }
        if (handle->output_fd != INVALID_HANDLE_VALUE) {
            CloseHandle(handle->output_fd);
        }
        if (handle->error_fd != INVALID_HANDLE_VALUE) {
            CloseHandle(handle->error_fd);
        }
        
        // Close process handle if we have it
        if (handle->hProcess != INVALID_HANDLE_VALUE) {
            // First try to terminate gently
            TerminateProcess(handle->hProcess, 0);
            
            // Wait for process to exit (with timeout)
            WaitForSingleObject(handle->hProcess, 5000); // 5 second timeout
            
            CloseHandle(handle->hProcess);
        }
        
        free(handle);
    }
}

int is_running(ProcessHandle* handle) {
    if (!handle || handle->hProcess == INVALID_HANDLE_VALUE) {
        return 0;
    }
    
    DWORD exitCode;
    if (GetExitCodeProcess(handle->hProcess, &exitCode)) {
        return (exitCode == STILL_ACTIVE) ? 1 : 0;
    }
    
    return 0;
}

int write_to_process(ProcessHandle* handle, const char* data, int length) {
    if (!handle || handle->input_fd == INVALID_HANDLE_VALUE) {
        return -1;
    }
    
    DWORD bytesWritten;
    BOOL success = WriteFile(handle->input_fd, data, length, &bytesWritten, NULL);
    
    if (!success) {
        DWORD err = GetLastError();
        if (err == ERROR_NO_DATA || err == ERROR_BROKEN_PIPE) {
            // Pipe was closed
            return 0;
        }
        return -1;
    }
    
    // Flush the write
    FlushFileBuffers(handle->input_fd);
    
    return (int)bytesWritten;
}

int read_from_output(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms) {
    if (!handle || handle->output_fd == INVALID_HANDLE_VALUE) {
        return -1;
    }
    return read_from_handle(handle->output_fd, buffer, buffer_size, timeout_ms);
}

int read_from_error(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms) {
    if (!handle || handle->error_fd == INVALID_HANDLE_VALUE) {
        return -1;
    }
    return read_from_handle(handle->error_fd, buffer, buffer_size, timeout_ms);
}

int read_available(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms, int* source) {
    if (!handle) return -1;
    
    HANDLE handles[2];
    int handleCount = 0;
    
    if (handle->output_fd != INVALID_HANDLE_VALUE) {
        handles[handleCount++] = handle->output_fd;
    }
    
    if (handle->error_fd != INVALID_HANDLE_VALUE) {
        handles[handleCount++] = handle->error_fd;
    }
    
    if (handleCount == 0) return -1;
    
    // Check which handle has data available
    DWORD waitResult = WaitForMultipleObjects(handleCount, handles, FALSE, timeout_ms);
    
    if (waitResult == WAIT_TIMEOUT) {
        return 0; // Timeout
    }
    
    if (waitResult >= WAIT_OBJECT_0 && waitResult < WAIT_OBJECT_0 + handleCount) {
        int index = waitResult - WAIT_OBJECT_0;
        HANDLE h = handles[index];
        
        if (source) {
            *source = (h == handle->output_fd) ? 1 : 2;
        }
        
        // Try to read from the handle that has data
        DWORD bytesRead;
        BOOL success = ReadFile(h, buffer, buffer_size - 1, &bytesRead, NULL);
        
        if (success && bytesRead > 0) {
            buffer[bytesRead] = '\0';
            return (int)bytesRead;
        } else if (GetLastError() == ERROR_BROKEN_PIPE) {
            // Pipe was closed
            return 0;
        }
    } else if (waitResult == WAIT_FAILED) {
        // Wait failed
        return -1;
    }
    
    return 0;
}

#endif // _WIN32