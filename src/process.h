// process.h
#ifndef PROCESS_H
#define PROCESS_H

#include <sys/types.h> // for pid_t

typedef struct {
    pid_t pid;
    int input_fd;   // File descriptor for writing to child's stdin
    int output_fd;  // File descriptor for reading from child's stdout
    int error_fd;   // File descriptor for reading from child's stderr
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

#endif