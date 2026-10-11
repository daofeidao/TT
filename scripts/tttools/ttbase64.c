/* ttbin/base64: encode or decode Base64.
 *
 * 只做标准 Base64（RFC 4648），编码按 76 列折行（GNU/BSD 的默认都是这个宽度）。
 * 用法: base64 [-d] [file...]
 * 不带文件时读 stdin。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

static const char kEncode[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static int decodeChar(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int encodeStream(FILE *in, FILE *out) {
    /* 57 = 3 * 19：19 组三字节正好编成 76 个字符，一行 */
    unsigned char buf[57];
    size_t n;

    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        size_t i = 0;
        while (i + 3 <= n) {
            unsigned v = ((unsigned)buf[i] << 16)
                       | ((unsigned)buf[i + 1] << 8)
                       | (unsigned)buf[i + 2];
            fputc(kEncode[(v >> 18) & 63], out);
            fputc(kEncode[(v >> 12) & 63], out);
            fputc(kEncode[(v >> 6) & 63], out);
            fputc(kEncode[v & 63], out);
            i += 3;
        }
        fputc('\n', out);
        if (n - i == 1) {
            unsigned v = (unsigned)buf[i] << 16;
            fputc(kEncode[(v >> 18) & 63], out);
            fputc(kEncode[(v >> 12) & 63], out);
            fputc('=', out);
            fputc('=', out);
        } else if (n - i == 2) {
            unsigned v = ((unsigned)buf[i] << 16) | ((unsigned)buf[i + 1] << 8);
            fputc(kEncode[(v >> 18) & 63], out);
            fputc(kEncode[(v >> 12) & 63], out);
            fputc(kEncode[(v >> 6) & 63], out);
            fputc('=', out);
        }
    }
    return 0;
}

static int decodeStream(FILE *in, FILE *out) {
    int c;
    unsigned acc = 0;
    int bits = 0;

    for (;;) {
        c = fgetc(in);
        if (c == EOF) break;
        if (c == '=') break;              /* 补齐符之后就没内容了 */
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        {
            int v = decodeChar(c);
            if (v < 0) {
                fprintf(stderr, "base64: 输入里有非法字符 '%c'\n", c);
                return 1;
            }
            /* bits 最大 12，acc 只用到低 18 位，unsigned 绰绰有余 */
            acc = (acc << 6) | (unsigned)v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                fputc((int)((acc >> bits) & 0xff), out);
            }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    int decode = 0;
    int i = 1;
    int status = 0;

    if (i < argc && strcmp(argv[i], "-d") == 0) {
        decode = 1;
        i++;
    }

    if (i >= argc) {
        return decode ? decodeStream(stdin, stdout) : encodeStream(stdin, stdout);
    }

    for (; i < argc; i++) {
        FILE *in = fopen(argv[i], "rb");
        int rc;
        if (!in) {
            fprintf(stderr, "base64: %s: %s\n", argv[i], strerror(errno));
            status = 1;
            continue;
        }
        rc = decode ? decodeStream(in, stdout) : encodeStream(in, stdout);
        fclose(in);
        if (rc) status = rc;
    }
    return status;
}