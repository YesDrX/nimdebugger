// process.c
#include "process.h"
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <errno.h>
#include <string.h>
#include <poll.h>
#include <stdio.h>

ProcessHandle* start_process(const char* cmd, char** args) {
    int child_stdin[2];
    int child_stdout[2];
    int child_stderr[2];

    if (pipe(child_stdin) == -1 || pipe(child_stdout) == -1 || pipe(child_stderr) == -1) {
        perror("pipe");
        return NULL;
    }

    pid_t pid = fork();
    if (pid == -1) {
        perror("fork");
        return NULL;
    }

    if (pid == 0) {  // Child
        // Close parent's ends
        close(child_stdin[1]);
        close(child_stdout[0]);
        close(child_stderr[0]);

        // Redirect standard streams
        dup2(child_stdin[0], STDIN_FILENO);
        dup2(child_stdout[1], STDOUT_FILENO);
        dup2(child_stderr[1], STDERR_FILENO);

        // Close original pipe descriptors
        close(child_stdin[0]);
        close(child_stdout[1]);
        close(child_stderr[1]);

        // Execute the command
        execvp(cmd, args);
        
        // If we get here, exec failed
        perror("execvp");
        exit(EXIT_FAILURE);
    } else {  // Parent
        // Close child's ends
        close(child_stdin[0]);
        close(child_stdout[1]);
        close(child_stderr[1]);

        // Set non-blocking on read ends
        fcntl(child_stdout[0], F_SETFL, O_NONBLOCK);
        fcntl(child_stderr[0], F_SETFL, O_NONBLOCK);

        // Allocate and initialize process handle
        ProcessHandle* handle = malloc(sizeof(ProcessHandle));
        if (!handle) {
            perror("malloc");
            close(child_stdin[1]);
            close(child_stdout[0]);
            close(child_stderr[0]);
            return NULL;
        }

        handle->pid = pid;
        handle->input_fd = child_stdin[1];
        handle->output_fd = child_stdout[0];
        handle->error_fd = child_stderr[0];

        return handle;
    }
}

void close_process(ProcessHandle* handle) {
    if (handle) {
        // Close all file descriptors
        if (handle->input_fd >= 0) close(handle->input_fd);
        if (handle->output_fd >= 0) close(handle->output_fd);
        if (handle->error_fd >= 0) close(handle->error_fd);
        
        // Wait for process to exit
        waitpid(handle->pid, NULL, 0);
        
        // Free memory
        free(handle);
    }
}

int is_running(ProcessHandle* handle) {
    if (!handle) return 0;
    
    int status;
    pid_t result = waitpid(handle->pid, &status, WNOHANG);
    
    if (result == 0) {
        return 1;  // Process is still running
    } else if (result == -1) {
        return 0;  // Error or process doesn't exist
    } else {
        return 0;  // Process has exited
    }
}

int write_to_process(ProcessHandle* handle, const char* data, int length) {
    if (!handle || handle->input_fd < 0) return -1;
    
    int total_written = 0;
    while (total_written < length) {
        int written = write(handle->input_fd, data + total_written, length - total_written);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        total_written += written;
    }
    
    // Flush the data
    fsync(handle->input_fd);
    
    return total_written;
}

int read_from_output(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms) {
    if (!handle || handle->output_fd < 0) return -1;
    
    struct pollfd pfd;
    pfd.fd = handle->output_fd;
    pfd.events = POLLIN;
    
    int poll_result = poll(&pfd, 1, timeout_ms);
    
    if (poll_result == -1) {
        return -1;  // poll error
    } else if (poll_result == 0) {
        return 0;   // timeout, no data available
    } else if (pfd.revents & POLLIN) {
        // Data is available to read
        int bytes_read = read(handle->output_fd, buffer, buffer_size - 1);
        if (bytes_read > 0) {
            buffer[bytes_read] = '\0';  // Null-terminate the string
        }
        return bytes_read;
    } else if (pfd.revents & POLLHUP) {
        return 0;  // EOF
    } else {
        return -1;  // Other poll event
    }
}

int read_from_error(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms) {
    if (!handle || handle->error_fd < 0) return -1;
    
    struct pollfd pfd;
    pfd.fd = handle->error_fd;
    pfd.events = POLLIN;
    
    int poll_result = poll(&pfd, 1, timeout_ms);
    
    if (poll_result == -1) {
        return -1;  // poll error
    } else if (poll_result == 0) {
        return 0;   // timeout, no data available
    } else if (pfd.revents & POLLIN) {
        // Data is available to read
        int bytes_read = read(handle->error_fd, buffer, buffer_size - 1);
        if (bytes_read > 0) {
            buffer[bytes_read] = '\0';  // Null-terminate the string
        }
        return bytes_read;
    } else if (pfd.revents & POLLHUP) {
        return 0;  // EOF
    } else {
        return -1;  // Other poll event
    }
}

int read_available(ProcessHandle* handle, char* buffer, int buffer_size, int timeout_ms, int* source) {
    if (!handle) return -1;
    
    struct pollfd pfds[2];
    int nfds = 0;
    
    if (handle->output_fd >= 0) {
        pfds[nfds].fd = handle->output_fd;
        pfds[nfds].events = POLLIN;
        nfds++;
    }
    
    if (handle->error_fd >= 0) {
        pfds[nfds].fd = handle->error_fd;
        pfds[nfds].events = POLLIN;
        nfds++;
    }
    
    if (nfds == 0) return -1;
    
    int poll_result = poll(pfds, nfds, timeout_ms);
    
    if (poll_result == -1) {
        return -1;  // poll error
    } else if (poll_result == 0) {
        return 0;   // timeout, no data available
    }
    
    // Check which file descriptor has data
    for (int i = 0; i < nfds; i++) {
        if (pfds[i].revents & POLLIN) {
            int fd_to_read;
            if (i == 0 && handle->output_fd >= 0) {
                fd_to_read = handle->output_fd;
                if (source) *source = 1;  // stdout
            } else {
                fd_to_read = handle->error_fd;
                if (source) *source = 2;  // stderr
            }
            
            int bytes_read = read(fd_to_read, buffer, buffer_size - 1);
            if (bytes_read > 0) {
                buffer[bytes_read] = '\0';  // Null-terminate the string
            }
            return bytes_read;
        }
    }
    
    return 0;
}