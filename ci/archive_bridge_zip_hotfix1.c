// archive_bridge.c — small, sandbox-safe libarchive extraction bridge.
//
// SwiftVLC's pinned libVLC static binary already contains libarchive.  We only
// forward-declare the stable C API surface we need here, so the app does not
// need a second archive framework or another copy of libarchive.

#include "CLibVLC.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

struct archive;
struct archive_entry;

extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_add_passphrase(struct archive *, const char *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_data_skip(struct archive *);
extern int archive_read_close(struct archive *);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);

#ifndef ARCHIVE_OK
#define ARCHIVE_OK 0
#endif
#ifndef ARCHIVE_EOF
#define ARCHIVE_EOF 1
#endif

static void set_error(char *buffer, size_t size, const char *message) {
    if (buffer == NULL || size == 0) {
        return;
    }
    if (message == NULL || message[0] == '\0') {
        message = "Unknown archive extraction error";
    }
    snprintf(buffer, size, "%s", message);
}

// Normalize an archive entry into a path that is guaranteed to stay relative to
// destination_path. Real-world ZIP files are often created with paths such as
// /folder/file, ../folder/file, ./folder/file, or Windows-style C:\\folder\file.
// Rejecting the whole archive for those metadata forms made otherwise valid ZIPs
// impossible to extract on iOS. Instead, normalize them into the sandbox:
//   /a/b        -> a/b
//   ../a/b      -> a/b
//   a/../b      -> b
//   C:\\a\b    -> a/b
// Symlinks and special files are still skipped later, so normalized entries
// cannot use a symlink to escape the destination either.
static char *normalize_archive_path(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NULL;
    }

    size_t length = strlen(path);
    char *working = (char *)malloc(length + 1);
    char *normalized = (char *)malloc(length + 1);
    if (working == NULL || normalized == NULL) {
        free(working);
        free(normalized);
        return NULL;
    }

    // Treat Windows separators the same as POSIX separators.
    for (size_t i = 0; i < length; ++i) {
        working[i] = path[i] == '\\' ? '/' : path[i];
    }
    working[length] = '\0';
    normalized[0] = '\0';

    size_t output_length = 0;
    size_t segment_index = 0;
    char *cursor = working;

    // Strip an absolute/UNC root. The entry will be materialized below the
    // selected extraction directory, never at the original absolute location.
    while (*cursor == '/') {
        ++cursor;
    }

    while (*cursor != '\0') {
        char *segment = cursor;
        while (*cursor != '\0' && *cursor != '/') {
            ++cursor;
        }
        size_t segment_length = (size_t)(cursor - segment);
        while (*cursor == '/') {
            ++cursor;
        }

        if (segment_length == 0 ||
            (segment_length == 1 && segment[0] == '.')) {
            continue;
        }

        // Strip a leading Windows drive prefix such as C: or D:.
        if (segment_index == 0 && segment_length == 2 &&
            ((segment[0] >= 'A' && segment[0] <= 'Z') ||
             (segment[0] >= 'a' && segment[0] <= 'z')) &&
            segment[1] == ':') {
            ++segment_index;
            continue;
        }
        ++segment_index;

        if (segment_length == 2 && segment[0] == '.' && segment[1] == '.') {
            // Resolve .. only inside our already-normalized relative path. If
            // there is nothing to pop, simply clamp at the extraction root.
            if (output_length > 0) {
                while (output_length > 0 && normalized[output_length - 1] != '/') {
                    --output_length;
                }
                if (output_length > 0 && normalized[output_length - 1] == '/') {
                    --output_length;
                }
                normalized[output_length] = '\0';
            }
            continue;
        }

        if (output_length > 0) {
            normalized[output_length++] = '/';
        }
        memcpy(normalized + output_length, segment, segment_length);
        output_length += segment_length;
        normalized[output_length] = '\0';
    }

    free(working);
    return normalized;
}

static int mkdir_recursive(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return -1;
    }

    char *copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }

    size_t length = strlen(copy);
    if (length > 1 && copy[length - 1] == '/') {
        copy[length - 1] = '\0';
    }

    for (char *cursor = copy + 1; *cursor != '\0'; ++cursor) {
        if (*cursor != '/') {
            continue;
        }
        *cursor = '\0';
        if (mkdir(copy, 0755) != 0 && errno != EEXIST) {
            free(copy);
            return -1;
        }
        *cursor = '/';
    }

    int result = 0;
    if (mkdir(copy, 0755) != 0 && errno != EEXIST) {
        result = -1;
    }
    free(copy);
    return result;
}

static int ensure_parent_directory(const char *path) {
    char *copy = strdup(path);
    if (copy == NULL) {
        return -1;
    }
    char *slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return 0;
    }
    *slash = '\0';
    int result = mkdir_recursive(copy);
    free(copy);
    return result;
}

static char *join_destination(const char *destination, const char *relative) {
    size_t a = strlen(destination);
    size_t b = strlen(relative);
    int needs_slash = a > 0 && destination[a - 1] != '/';
    char *result = (char *)malloc(a + (size_t)needs_slash + b + 1);
    if (result == NULL) {
        return NULL;
    }
    memcpy(result, destination, a);
    size_t offset = a;
    if (needs_slash) {
        result[offset++] = '/';
    }
    memcpy(result + offset, relative, b);
    result[offset + b] = '\0';
    return result;
}

int swiftvlc_archive_extract(const char *archive_path,
                             const char *destination_path,
                             const char *password,
                             char *error_buffer,
                             size_t error_buffer_size) {
    if (archive_path == NULL || destination_path == NULL) {
        set_error(error_buffer, error_buffer_size, "Archive path or destination is missing");
        return 2;
    }

    if (mkdir_recursive(destination_path) != 0) {
        set_error(error_buffer, error_buffer_size, "Unable to create extraction directory");
        return 3;
    }

    struct archive *archive = archive_read_new();
    if (archive == NULL) {
        set_error(error_buffer, error_buffer_size, "Unable to initialize archive reader");
        return 4;
    }

    (void)archive_read_support_filter_all(archive);
    (void)archive_read_support_format_all(archive);

    if (password != NULL && password[0] != '\0') {
        int password_result = archive_read_add_passphrase(archive, password);
        if (password_result < ARCHIVE_OK) {
            set_error(error_buffer, error_buffer_size, archive_error_string(archive));
            archive_read_free(archive);
            return 5;
        }
    }

    int open_result = archive_read_open_filename(archive, archive_path, 10240);
    if (open_result < ARCHIVE_OK) {
        set_error(error_buffer, error_buffer_size, archive_error_string(archive));
        archive_read_free(archive);
        return 6;
    }

    int result = 0;
    struct archive_entry *entry = NULL;
    unsigned char io_buffer[64 * 1024];

    while (1) {
        int header_result = archive_read_next_header(archive, &entry);
        if (header_result == ARCHIVE_EOF) {
            break;
        }
        if (header_result < ARCHIVE_OK) {
            set_error(error_buffer, error_buffer_size, archive_error_string(archive));
            result = 7;
            break;
        }

        const char *entry_path = archive_entry_pathname(entry);
        char *relative_path = normalize_archive_path(entry_path);
        if (relative_path == NULL) {
            set_error(error_buffer, error_buffer_size, "Out of memory while normalizing archive path");
            result = 8;
            break;
        }

        // Some archives contain a root-only entry such as "/" or "../".
        // It carries no extractable filename after normalization, so skip it.
        if (relative_path[0] == '\0') {
            (void)archive_read_data_skip(archive);
            free(relative_path);
            continue;
        }

        char *output_path = join_destination(destination_path, relative_path);
        free(relative_path);
        if (output_path == NULL) {
            set_error(error_buffer, error_buffer_size, "Out of memory while extracting archive");
            result = 9;
            break;
        }

        mode_t type = archive_entry_filetype(entry);
        if (type == S_IFDIR) {
            if (mkdir_recursive(output_path) != 0) {
                set_error(error_buffer, error_buffer_size, "Unable to create a directory from the archive");
                free(output_path);
                result = 10;
                break;
            }
            free(output_path);
            continue;
        }

        // For safety, only materialize regular files and directories. Symlinks,
        // device nodes and other special entries are skipped inside the app sandbox.
        if (type != S_IFREG && type != 0) {
            (void)archive_read_data_skip(archive);
            free(output_path);
            continue;
        }

        if (ensure_parent_directory(output_path) != 0) {
            set_error(error_buffer, error_buffer_size, "Unable to create a parent directory while extracting");
            free(output_path);
            result = 11;
            break;
        }

        FILE *output = fopen(output_path, "wb");
        if (output == NULL) {
            set_error(error_buffer, error_buffer_size, "Unable to create an extracted file");
            free(output_path);
            result = 12;
            break;
        }

        while (1) {
            ssize_t count = archive_read_data(archive, io_buffer, sizeof(io_buffer));
            if (count == 0) {
                break;
            }
            if (count < 0) {
                set_error(error_buffer, error_buffer_size, archive_error_string(archive));
                result = 13;
                break;
            }
            if (fwrite(io_buffer, 1, (size_t)count, output) != (size_t)count) {
                set_error(error_buffer, error_buffer_size, "Unable to write an extracted file");
                result = 14;
                break;
            }
        }

        if (fclose(output) != 0 && result == 0) {
            set_error(error_buffer, error_buffer_size, "Unable to finish writing an extracted file");
            result = 15;
        }
        free(output_path);

        if (result != 0) {
            break;
        }
    }

    archive_read_close(archive);
    archive_read_free(archive);
    return result;
}
