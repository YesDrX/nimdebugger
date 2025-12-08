// process_windows.h
#ifndef PROCESS_WINDOWS_H
#define PROCESS_WINDOWS_H

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef struct {
    DWORD pid;
    HANDLE hProcess;     // Process handle for waiting and status
    HANDLE input_fd;     // Handle for writing to child's stdin
    HANDLE output_fd;    // Handle for reading from child's stdout  
    HANDLE error_fd;     // Handle for reading from child's stderr
} ProcessHandle;

// Create a process with redirected I/O
ProcessHandle* start_process(const char* cmd, char** args);

// Close process and free resources
void close_process(ProcessHandle* handle);

// Check if process is still running
int is_running(ProcessHandle* handle);

// Write to process stdin
int write_to_process(ProcessHandle* handle, const char* data, int length);

// Read from process stdout
int read_from_output(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms);

// Read from process stderr
int read_from_error(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms);

// Read from either stdout or stderr (whichever has data)
int read_available(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms, int* source);

#endif // _WIN32

#endif // PROCESS_WINDOWS_H