#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>

/* ttbin/wc: count lines, words and bytes. Supports -l -w -c. */
int main(int argc, char **argv) {
    long lines = 0, words = 0, chars = 0;
    int showLines = 1, showWords = 1, showChars = 1;
    int sawOption = 0;

    const char **files = calloc((size_t)(argc > 1 ? argc : 1), sizeof(char *));
    int fileCount = 0;

    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-' && argv[i][1] != '\0') {
            sawOption = 1;
            for (const char *flag = argv[i] + 1; *flag; flag++) {
                if (*flag == 'l') { showLines = 1; showWords = 0; showChars = 0; }
                else if (*flag == 'w') { showWords = 1; showLines = 0; showChars = 0; }
                else if (*flag == 'c') { showChars = 1; showLines = 0; showWords = 0; }
                else { fprintf(stderr, "wc: unsupported option -%c\n", *flag); free(files); return 1; }
            }
        } else {
            files[fileCount++] = argv[i];
        }
    }
    if (!sawOption) {
        showLines = showWords = showChars = 1;
    }

    if (fileCount == 0) {
        files[fileCount++] = "-";
    }

    for (int index = 0; index < fileCount; index++) {
        FILE *input = stdin;
        int closeIt = 0;
        if (strcmp(files[index], "-") != 0) {
            input = fopen(files[index], "r");
            if (!input) {
                fprintf(stderr, "wc: %s: %s\n", files[index], strerror(errno));
                free(files);
                return 1;
            }
            closeIt = 1;
        }
        int c;
        int inWord = 0;
        while ((c = fgetc(input)) != EOF) {
            chars++;
            if (c == '\n') lines++;
            if (isspace(c)) {
                inWord = 0;
            } else if (!inWord) {
                inWord = 1;
                words++;
            }
        }
        if (closeIt) fclose(input);
    }

    if (showLines) printf("%8ld", lines);
    if (showWords) printf("%8ld", words);
    if (showChars) printf("%8ld", chars);
    printf("\n");
    free(files);
    return 0;
}