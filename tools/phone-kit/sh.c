/* A small POSIX-like shell for Henge's terminal tools (tl/loader/tl_tool.h), where no process can be made: pipelines run
   one part after another through a temporary file, and what is usually in /bin is built in. For build scripts; no job
   control, functions or case. */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <limits.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <copyfile.h>
#include <ftw.h>

#include <crt_externs.h>
#define environ (*_NSGetEnviron())
typedef struct { int in, out, err; } Io;
static int last, e_flag, x_flag, quitting, loop_go; /* loop_go: 1 break, 2 continue */
static char **pos;
static int npos;

typedef struct { char *p; size_t n, cap; } Buf;
static void put(Buf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) b->p = realloc(b->p, b->cap = (b->n + n + 1) * 2);
    memcpy(b->p + b->n, s, n);
    b->p[b->n += n] = 0;
}
static void putc1(Buf *b, char c) { put(b, &c, 1); }
static void say(int fd, const char *f, ...) {
    va_list a;
    va_start(a, f);
    char *s = NULL;
    int n = vasprintf(&s, f, a);
    va_end(a);
    for (int k = 0; k < n;) {
        ssize_t w = write(fd, s + k, (size_t)(n - k));
        if (w <= 0) break;
        k += (int)w;
    }
    free(s);
}

/* ---- tokens ---- */
typedef struct { char *s; int op; } Tok; /* op: an operator; words keep their quotes */
typedef struct { Tok *t; int n, cap, at; } Toks;
static void add_tok(Toks *t, char *s, int op) {
    if (t->n == t->cap) t->t = realloc(t->t, sizeof(Tok) * (size_t)(t->cap = t->cap * 2 + 64));
    t->t[t->n++] = (Tok){s, op};
}
static const char *skip_sub(const char *p) { /* past the ) of $( */
    int d = 1;
    for (; *p && d; p++) {
        if (*p == '\\' && p[1]) p++;
        else if (*p == '\'') { for (p++; *p && *p != '\''; p++); if (!*p) break; }
        else if (*p == '(') d++;
        else if (*p == ')') d--;
    }
    return p;
}
static const char *word_end(const char *p) {
    while (*p && !strchr(" \t\r\n;&|<>()", *p)) {
        if (*p == '\\' && p[1]) p += 2;
        else if (*p == '\'') { for (p++; *p && *p != '\''; p++); if (*p) p++; }
        else if (*p == '"') {
            for (p++; *p && *p != '"'; p++) {
                if (*p == '\\' && p[1]) p++;
                else if (*p == '$' && p[1] == '(') p = skip_sub(p + 2) - 1;
            }
            if (*p) p++;
        }
        else if (*p == '`') { for (p++; *p && *p != '`'; p++); if (*p) p++; }
        else if (*p == '$' && p[1] == '(') p = skip_sub(p + 2);
        else if (*p == '$' && p[1] == '{') { while (*p && *p != '}') p++; if (*p) p++; }
        else p++;
    }
    return p;
}
static Toks lex(const char *p) {
    static const char *const ops[] = {"&&", "||", ">>", "2>>", "2>&1", "1>&2", ">&2", "&>", "2>", "1>", ";;", "<", ">", ";", "|", "&", "(", ")", NULL};
    Toks t = {0};
    while (*p) {
        if (*p == '\\' && p[1] == '\n') { p += 2; continue; }
        if (*p == ' ' || *p == '\t' || *p == '\r') { p++; continue; }
        if (*p == '\n') { add_tok(&t, strdup("\n"), 1); p++; continue; }
        if (*p == '#') { while (*p && *p != '\n') p++; continue; }
        const char *op = NULL;
        for (int i = 0; ops[i]; i++)
            if (!strncmp(p, ops[i], strlen(ops[i])) && (!op || strlen(ops[i]) > strlen(op))) op = ops[i];
        if (op) { add_tok(&t, strdup(op), 1); p += strlen(op); continue; }
        const char *e = word_end(p);
        if (e == p) e++;
        add_tok(&t, strndup(p, (size_t)(e - p)), 0);
        p = e;
    }
    return t;
}

/* ---- expansion ---- */
static int run_text(const char *text, Io io);
static void capture(const char *cmd, Buf *b) {
    char name[] = "/sh.XXXXXX", path[PATH_MAX];
    const char *tmp = getenv("TMPDIR");
    snprintf(path, sizeof path, "%s%s", tmp ? tmp : "/tmp", name);
    int fd = mkstemp(path);
    if (fd < 0) return;
    unlink(path);
    int was = quitting;
    last = run_text(cmd, (Io){0, fd, 2});
    quitting = was;
    lseek(fd, 0, SEEK_SET);
    char c[4096];
    ssize_t n;
    while ((n = read(fd, c, sizeof c)) > 0) put(b, c, (size_t)n);
    close(fd);
    while (b->n && b->p[b->n - 1] == '\n') b->p[--b->n] = 0;
}
static const char *var(const char *name, char *num) {
    if (!strcmp(name, "?")) { sprintf(num, "%d", last); return num; }
    if (!strcmp(name, "#")) { sprintf(num, "%d", npos > 0 ? npos - 1 : 0); return num; }
    if (!strcmp(name, "$")) return "1";
    if (isdigit((unsigned char)name[0])) { int i = atoi(name); return i < npos ? pos[i] : ""; }
    return getenv(name);
}
typedef struct { char **v; int n, cap; } Words;
static void add_word(Words *w, char *s) {
    if (w->n + 2 > w->cap) w->v = realloc(w->v, sizeof(char *) * (size_t)(w->cap = w->cap * 2 + 16));
    w->v[w->n++] = s;
    w->v[w->n] = NULL;
}
/* cur: the word so far; a glob character inside quotes is kept as \\x for glob(). */
typedef struct { Buf cur; int any, magic; } Ex;
static char *plain(const char *s) {
    Buf b = {0};
    put(&b, "", 0);
    for (; *s; s++) { if (*s == '\\' && s[1]) s++; putc1(&b, *s); }
    return b.p;
}
static void flush(Words *w, Ex *x) {
    if (x->any) {
        glob_t g;
        if (x->magic && !glob(x->cur.p, 0, NULL, &g)) {
            for (size_t i = 0; i < g.gl_pathc; i++) add_word(w, strdup(g.gl_pathv[i]));
            globfree(&g);
        } else add_word(w, plain(x->cur.p ? x->cur.p : ""));
    }
    free(x->cur.p);
    *x = (Ex){0};
}
static void lit(Ex *x, char c, int quoted) {
    x->any = 1;
    if (quoted ? strchr("*?[]\\", c) != NULL : c == '\\') putc1(&x->cur, '\\');
    if (!quoted && strchr("*?[", c)) x->magic = 1;
    putc1(&x->cur, c);
}
static void value(Words *w, Ex *x, const char *s, int quoted, int split) {
    if (quoted) x->any = 1;
    for (; s && *s; s++) {
        if (!quoted && split && strchr(" \t\n", *s)) { flush(w, x); continue; }
        lit(x, *s, quoted);
    }
}
static const char *dollar(const char *p, Words *w, Ex *x, int quoted, int split) { /* after $ */
    char num[32];
    if (*p == '(') {
        const char *e = skip_sub(p + 1);
        char *cmd = strndup(p + 1, (size_t)(e - p - 2));
        Buf b = {0};
        capture(cmd, &b);
        value(w, x, b.p, quoted, split);
        free(cmd), free(b.p);
        return e;
    }
    char name[256] = "", *alt = NULL;
    int kind = 0;
    if (*p == '{') {
        const char *e = strchr(p, '}');
        if (!e) return p;
        size_t n = 0;
        for (p++; p < e && (isalnum((unsigned char)*p) || *p == '_' || (!n && strchr("?#@*", *p))) && n < 255;) name[n++] = *p++;
        name[n] = 0;
        if (p < e) { if (*p == ':') p++; kind = *p++; alt = strndup(p, (size_t)(e - p)); }
        p = e + 1;
    } else if (strchr("?#@*$", *p) && *p) { name[0] = *p++; }
    else if (isdigit((unsigned char)*p)) { name[0] = *p++; }
    else {
        size_t n = 0;
        while ((isalnum((unsigned char)*p) || *p == '_') && n < 255) name[n++] = *p++;
        name[n] = 0;
        if (!n) { lit(x, '$', quoted); return p; }
    }
    if (!strcmp(name, "@") || !strcmp(name, "*")) {
        for (int i = 1; i < npos; i++) {
            if (i > 1) { if (quoted && name[0] == '*') lit(x, ' ', 1); else flush(w, x); }
            value(w, x, pos[i], quoted, split);
        }
    } else {
        const char *v = var(name, num);
        int set = v && *v;
        if (kind == '-' || kind == '=') { if (!set) v = alt; if (kind == '=' && !set && alt) setenv(name, alt, 1); }
        else if (kind == '+') v = set ? alt : "";
        else if (kind == '%' && v && alt) { /* suffix, plain or *.x */
            char *q = strdup(v);
            const char *a = alt[0] == '%' ? alt + 1 : alt;
            if (a[0] && a[strlen(a) - 1] == '*') { char *k = strstr(q, strndup(a, strlen(a) - 1)); if (k) *k = 0; }
            else if (strlen(q) >= strlen(a) && !strcmp(q + strlen(q) - strlen(a), a)) q[strlen(q) - strlen(a)] = 0;
            v = q;
        }
        value(w, x, v, quoted, split);
    }
    free(alt);
    return p;
}
static void expand(const char *p, Words *w, int split) {
    Ex x = {0};
    if (*p == '~' && (!p[1] || p[1] == '/')) { value(w, &x, getenv("HOME"), 1, 0); p++; }
    while (*p) {
        if (*p == '\\' && p[1]) { if (p[1] != '\n') lit(&x, p[1], 1); p += 2; }
        else if (*p == '\'') { x.any = 1; for (p++; *p && *p != '\''; p++) lit(&x, *p, 1); if (*p) p++; }
        else if (*p == '"') {
            x.any = 1;
            for (p++; *p && *p != '"';) {
                if (*p == '\\' && p[1] && strchr("\"\\$`\n", p[1])) { if (p[1] != '\n') lit(&x, p[1], 1); p += 2; }
                else if (*p == '$') p = dollar(p + 1, w, &x, 1, 0);
                else lit(&x, *p++, 1);
            }
            if (*p) p++;
        }
        else if (*p == '`') {
            const char *e = strchr(p + 1, '`');
            if (!e) break;
            char *cmd = strndup(p + 1, (size_t)(e - p - 1));
            Buf b = {0};
            capture(cmd, &b);
            value(w, &x, b.p, 0, split);
            free(cmd), free(b.p);
            p = e + 1;
        }
        else if (*p == '$') p = dollar(p + 1, w, &x, 0, split);
        else lit(&x, *p++, 0);
    }
    if (!split) x.magic = 0;
    flush(w, &x);
}
static char *expand1(const char *p) {
    Words w = {0};
    expand(p, &w, 0);
    return w.n ? w.v[0] : strdup("");
}

/* ---- built in ---- */
static int fail(Io io, const char *what, const char *who) { say(io.err, "%s: %s: %s\n", what, who, strerror(errno)); return 1; }
static int rm_one(const char *p, const struct stat *s, int f, struct FTW *w) { (void)s, (void)f, (void)w; return remove(p); }
static int mkdirs(char *p) {
    for (char *q = p + 1; *q; q++)
        if (*q == '/') { *q = 0; if (mkdir(p, 0777) && errno != EEXIST) { *q = '/'; return -1; } *q = '/'; }
    return mkdir(p, 0777) && errno != EEXIST ? -1 : 0;
}
static int cat_fd(int from, int to) {
    char b[65536];
    ssize_t n;
    while ((n = read(from, b, sizeof b)) > 0)
        for (ssize_t k = 0; k < n;) { ssize_t w = write(to, b + k, (size_t)(n - k)); if (w <= 0) return 1; k += w; }
    return 0;
}
static int test_one(int n, char **v) {
    struct stat s;
    if (n == 0) return 1;
    if (!strcmp(v[0], "!")) return !test_one(n - 1, v + 1);
    for (int i = 1; i < n; i++) {
        if (!strcmp(v[i], "-a")) return test_one(i, v) || test_one(n - i - 1, v + i + 1);
        if (!strcmp(v[i], "-o")) return test_one(i, v) && test_one(n - i - 1, v + i + 1);
    }
    if (n == 1) return !*v[0];
    if (n == 2) {
        if (!strcmp(v[0], "-z")) return *v[1] != 0;
        if (!strcmp(v[0], "-n")) return *v[1] == 0;
        if (stat(v[1], &s)) return 1;
        if (!strcmp(v[0], "-f")) return !S_ISREG(s.st_mode);
        if (!strcmp(v[0], "-d")) return !S_ISDIR(s.st_mode);
        if (!strcmp(v[0], "-s")) return s.st_size == 0;
        return 0;
    }
    if (!strcmp(v[1], "=") || !strcmp(v[1], "==")) return strcmp(v[0], v[2]) != 0;
    if (!strcmp(v[1], "!=")) return strcmp(v[0], v[2]) == 0;
    long a = atol(v[0]), b = atol(v[2]);
    const char *o = v[1];
    return !(!strcmp(o, "-eq") ? a == b : !strcmp(o, "-ne") ? a != b : !strcmp(o, "-lt") ? a < b : !strcmp(o, "-le") ? a <= b : !strcmp(o, "-gt") ? a > b : a >= b);
}
static int by_name(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static int has(int n, char **v, char c) {
    for (int i = 1; i < n; i++) if (v[i][0] == '-' && v[i][1] && v[i][1] != '-' && strchr(v[i], c)) return 1;
    return 0;
}
static void ls_dir(const char *d, int all, int lng, int rec, Io io) {
    DIR *h = opendir(d);
    if (!h) return;
    Words w = {0};
    for (struct dirent *e; (e = readdir(h));) if (all ? strcmp(e->d_name, ".") && strcmp(e->d_name, "..") : e->d_name[0] != '.') add_word(&w, strdup(e->d_name));
    closedir(h);
    if (w.n) qsort(w.v, (size_t)w.n, sizeof *w.v, by_name);
    for (int i = 0; i < w.n; i++) {
        char p[PATH_MAX];
        struct stat s = {0};
        snprintf(p, sizeof p, "%s/%s", d, w.v[i]);
        stat(p, &s);
        if (lng) say(io.out, "%c %12lld  ", S_ISDIR(s.st_mode) ? 'd' : '-', (long long)s.st_size);
        say(io.out, "%s%s\n", rec ? p : w.v[i], S_ISDIR(s.st_mode) && lng ? "/" : "");
        if (rec && S_ISDIR(s.st_mode)) ls_dir(p, all, lng, rec, io);
    }
}
/* 0: not built in. */
static int builtin(int n, char **v, Io io, int *rc) {
    const char *c = v[0];
    if (strrchr(c, '/') && (!strncmp(c, "/bin/", 5) || !strncmp(c, "/usr/bin/", 9))) c = strrchr(c, '/') + 1;
    *rc = 0;
#define IS(x) (!strcmp(c, x))
    if (IS(":") || IS("true") || IS("umask") || IS("ulimit") || IS("trap") || IS("wait") || IS("sync")) return 1;
    if (IS("false")) return *rc = 1;
    if (IS("exit")) { quitting = 1; *rc = n > 1 ? atoi(v[1]) : last; return 1; }
    if (IS("break")) { loop_go = 1; return 1; }
    if (IS("continue")) { loop_go = 2; return 1; }
    if (IS("cd")) { const char *d = n > 1 ? v[1] : getenv("HOME"); if (chdir(d ? d : "/")) *rc = fail(io, "cd", d); else { char p[PATH_MAX]; if (getcwd(p, sizeof p)) setenv("PWD", p, 1); } return 1; }
    if (IS("pwd")) { char p[PATH_MAX]; say(io.out, "%s\n", getcwd(p, sizeof p)); return 1; }
    if (IS("echo")) {
        int i = 1, nl = 1;
        for (; i < n && (!strcmp(v[i], "-n") || !strcmp(v[i], "-e")); i++) if (v[i][1] == 'n') nl = 0;
        Buf b = {0};
        put(&b, "", 0);
        for (; i < n; i++) { put(&b, v[i], strlen(v[i])); if (i + 1 < n) putc1(&b, ' '); }
        if (nl) putc1(&b, '\n');
        say(io.out, "%s", b.p);
        free(b.p);
        return 1;
    }
    if (IS("printf")) {
        int a = 2;
        do {
            for (const char *p = n > 1 ? v[1] : ""; *p; p++) {
                if (*p == '\\' && p[1]) { p++; say(io.out, "%c", *p == 'n' ? '\n' : *p == 't' ? '\t' : *p); }
                else if (*p == '%' && p[1] == '%') { p++; say(io.out, "%%"); }
                else if (*p == '%') {
                    char f[32] = "%";
                    size_t k = 1;
                    for (p++; *p && !isalpha((unsigned char)*p) && k < 20; p++) f[k++] = *p;
                    const char *x = a < n ? v[a++] : "";
                    if (strchr("dixXuo", *p)) { f[k++] = 'l'; f[k++] = *p; f[k] = 0; say(io.out, f, strtol(x, NULL, 0)); }
                    else { f[k++] = 's'; f[k] = 0; say(io.out, f, x); }
                } else say(io.out, "%c", *p);
            }
        } while (a < n && a > 2);
        return 1;
    }
    if (IS("export") || IS("readonly") || IS("local")) { for (int i = 1; i < n; i++) { char *e = strchr(v[i], '='); if (e) { *e = 0; setenv(v[i], e + 1, 1); } } return 1; }
    if (IS("unset")) { for (int i = 1; i < n; i++) unsetenv(v[i]); return 1; }
    if (IS("env") && n == 1) { for (char **e = environ; *e; e++) say(io.out, "%s\n", *e); return 1; }
    if (IS("set")) { for (int i = 1; i < n; i++) if (v[i][0] == '-' || v[i][0] == '+') { if (strchr(v[i], 'e')) e_flag = v[i][0] == '-'; if (strchr(v[i], 'x')) x_flag = v[i][0] == '-'; } return 1; }
    if (IS("shift")) { if (npos > 1) { pos++, npos--; } return 1; }
    if (IS("test")) { *rc = test_one(n - 1, v + 1); return 1; }
    if (IS("[") || IS("[[")) { *rc = test_one(n - 2, v + 1); return 1; }
    if (IS("sleep")) { usleep((useconds_t)(atof(n > 1 ? v[1] : "0") * 1e6)); return 1; }
    if (IS("uname")) { say(io.out, has(n, v, 'm') ? "arm64\n" : "Darwin\n"); return 1; }
    if (IS("nproc")) { say(io.out, "2\n"); return 1; }
    if (IS("mktemp")) { char p[PATH_MAX]; snprintf(p, sizeof p, "%s/tmp.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp"); if (has(n, v, 'd')) mkdtemp(p); else { int fd = mkstemp(p); if (fd >= 0) close(fd); } say(io.out, "%s\n", p); return 1; }
    if (IS("basename") && n > 1) { char *b = strrchr(v[1], '/'); b = b ? b + 1 : v[1]; if (n > 2 && strlen(b) > strlen(v[2]) && !strcmp(b + strlen(b) - strlen(v[2]), v[2])) b[strlen(b) - strlen(v[2])] = 0; say(io.out, "%s\n", b); return 1; }
    if (IS("dirname") && n > 1) { char *b = strrchr(v[1], '/'); if (b) *b = 0; say(io.out, "%s\n", b ? (*v[1] ? v[1] : "/") : "."); return 1; }
    if (IS("mkdir")) { for (int i = 1; i < n; i++) if (v[i][0] != '-' && (has(n, v, 'p') ? mkdirs(v[i]) : mkdir(v[i], 0777))) *rc = fail(io, c, v[i]); return 1; }
    if (IS("rmdir")) { for (int i = 1; i < n; i++) if (v[i][0] != '-' && rmdir(v[i])) *rc = fail(io, c, v[i]); return 1; }
    if (IS("touch")) { for (int i = 1; i < n; i++) { int fd = open(v[i], O_CREAT | O_WRONLY, 0666); if (fd < 0) *rc = fail(io, c, v[i]); else { futimens(fd, NULL); close(fd); } } return 1; }
    if (IS("chmod")) { for (int i = 2; i < n; i++) { struct stat s; if (stat(v[i], &s)) { *rc = fail(io, c, v[i]); continue; } chmod(v[i], isdigit((unsigned char)v[1][0]) ? (mode_t)strtol(v[1], NULL, 8) : strchr(v[1], 'x') ? s.st_mode | 0111 : s.st_mode); } return 1; }
    if (IS("rm")) {
        int r = has(n, v, 'r') || has(n, v, 'R'), f = has(n, v, 'f');
        for (int i = 1; i < n; i++) {
            if (v[i][0] == '-') continue;
            struct stat s;
            if (lstat(v[i], &s)) { if (!f) *rc = fail(io, c, v[i]); }
            else if (S_ISDIR(s.st_mode) ? !r || nftw(v[i], rm_one, 16, FTW_DEPTH | FTW_PHYS) : unlink(v[i])) *rc = fail(io, c, v[i]);
        }
        return 1;
    }
    if (IS("cp") || IS("mv") || IS("ln")) {
        int first = 1, k = 0;
        char *files[4096];
        for (int i = first; i < n && k < 4096; i++) if (v[i][0] != '-' || !v[i][1]) files[k++] = v[i];
        if (k < 2) { say(io.err, "%s: needs a source and a destination\n", c); return *rc = 1; }
        struct stat s;
        int dir = !stat(files[k - 1], &s) && S_ISDIR(s.st_mode);
        for (int i = 0; i < k - 1; i++) {
            char to[PATH_MAX], src[PATH_MAX];
            snprintf(src, sizeof src, "%s", files[i]);
            while (strlen(src) > 1 && src[strlen(src) - 1] == '/') src[strlen(src) - 1] = 0;
            char *b = strrchr(src, '/');
            if (dir) snprintf(to, sizeof to, "%s/%s", files[k - 1], b ? b + 1 : src);
            else snprintf(to, sizeof to, "%s", files[k - 1]);
            int bad;
            if (IS("ln")) { if (has(n, v, 'f')) unlink(to); bad = has(n, v, 's') ? symlink(src, to) : link(src, to); }
            else if (IS("mv") && !rename(src, to)) bad = 0;
            else {
                struct stat f;
                bad = stat(src, &f);
                if (!bad && S_ISDIR(f.st_mode) && !has(n, v, 'r') && !has(n, v, 'R') && !has(n, v, 'a') && !IS("mv")) { errno = EISDIR; bad = 1; }
                if (!bad) bad = copyfile(src, to, NULL, (S_ISDIR(f.st_mode) ? COPYFILE_RECURSIVE : 0) | COPYFILE_DATA | COPYFILE_STAT) < 0;
                if (!bad && IS("mv")) nftw(src, rm_one, 16, FTW_DEPTH | FTW_PHYS);
            }
            if (bad) *rc = fail(io, c, src);
        }
        return 1;
    }
    if (IS("cat")) {
        if (n == 1) return cat_fd(io.in, io.out), 1;
        for (int i = 1; i < n; i++) { int fd = open(v[i], O_RDONLY); if (fd < 0) { *rc = fail(io, c, v[i]); continue; } cat_fd(fd, io.out); close(fd); }
        return 1;
    }
    if (IS("head") || IS("tail") || IS("wc")) {
        long k = 10;
        int i = 1, only = IS("wc") && has(n, v, 'l');
        for (; i < n && v[i][0] == '-'; i++) if (!IS("wc")) k = isdigit((unsigned char)v[i][1]) ? atol(v[i] + 1) : v[i][2] ? atol(v[i] + 2) : i + 1 < n ? atol(v[++i]) : 10;
        int fd = i < n ? open(v[i], O_RDONLY) : io.in;
        if (fd < 0) { *rc = fail(io, c, v[i]); return 1; }
        FILE *f = fdopen(dup(fd), "r");
        char *line = NULL;
        size_t cap = 0;
        ssize_t l;
        long count = 0, bytes = 0;
        char **keep = calloc((size_t)(k > 0 ? k : 1), sizeof *keep);
        while (f && (l = getline(&line, &cap, f)) >= 0) {
            bytes += l;
            if (IS("head") && count < k) say(io.out, "%s", line);
            if (IS("tail") && k > 0) { free(keep[count % k]); keep[count % k] = strdup(line); }
            count++;
        }
        if (IS("tail")) for (long j = count > k ? count - k : 0; j < count; j++) say(io.out, "%s", keep[j % k]);
        if (IS("wc")) { if (only) say(io.out, "%ld\n", count); else say(io.out, "%ld %ld\n", count, bytes); }
        if (f) fclose(f);
        if (fd != io.in) close(fd);
        return 1;
    }
    if (IS("ls")) {
        int some = 0;
        for (int i = 1; i < n; i++) {
            if (v[i][0] == '-') continue;
            some = 1;
            struct stat s;
            if (stat(v[i], &s)) *rc = fail(io, c, v[i]);
            else if (S_ISDIR(s.st_mode) && !has(n, v, 'd')) ls_dir(v[i], has(n, v, 'a'), has(n, v, 'l'), has(n, v, 'R'), io);
            else say(io.out, "%s\n", v[i]);
        }
        if (!some) ls_dir(".", has(n, v, 'a'), has(n, v, 'l'), has(n, v, 'R'), io);
        return 1;
    }
    if (IS(".") || IS("source")) {
        int fd = n > 1 ? open(v[1], O_RDONLY) : -1;
        if (fd < 0) { *rc = fail(io, c, n > 1 ? v[1] : ""); return 1; }
        Buf b = {0};
        char t[4096];
        ssize_t k;
        while ((k = read(fd, t, sizeof t)) > 0) put(&b, t, (size_t)k);
        close(fd);
        *rc = run_text(b.p ? b.p : "", io);
        return 1;
    }
    if (IS("which") || (IS("command") && n > 1 && !strcmp(v[1], "-v"))) {
        const char *name = v[n - 1], *path = getenv("PATH");
        char p[PATH_MAX];
        *rc = 1;
        for (const char *s = path; s && *s;) {
            const char *e = strchr(s, ':');
            snprintf(p, sizeof p, "%.*s/%s", (int)(e ? e - s : (long)strlen(s)), s, name);
            if (!access(p, F_OK)) { say(io.out, "%s\n", p); *rc = 0; break; }
            s = e ? e + 1 : NULL;
        }
        return 1;
    }
    return 0;
}

/* ---- running ---- */
static int spawn(int n, char **v, Io io);
/* ar, as libtool: the archive holds the objects named (nothing of an older one). */
static int ar(int n, char **v, Io io) {
    Words w = {0};
    add_word(&w, "libtool");
    add_word(&w, "-static");
    add_word(&w, "-no_warning_for_no_symbols");
    add_word(&w, "-o");
    int i = 1;
    if (n > 1 && strchr(v[1], 't')) { say(io.err, "ar: listing is not supported here\n"); return 1; }
    for (int k = 2; k < n; k++) add_word(&w, v[k]);
    (void)i;
    return w.n > 5 ? spawn(w.n, w.v, io) : 0;
}
static int spawn(int n, char **v, Io io) {
    (void)n;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (io.out == 2) posix_spawn_file_actions_adddup2(&fa, 2, 1);
    if (io.err == 1) posix_spawn_file_actions_adddup2(&fa, 1, 2);
    if (io.in != 0) posix_spawn_file_actions_adddup2(&fa, io.in, 0);
    if (io.out > 2) posix_spawn_file_actions_adddup2(&fa, io.out, 1);
    if (io.err > 2) posix_spawn_file_actions_adddup2(&fa, io.err, 2);
    pid_t pid;
    char path[PATH_MAX];
    int rc = ENOENT;
    if (strchr(v[0], '/')) {
        /* A script runs by its first line. */
        char head[512] = "";
        int fd = open(v[0], O_RDONLY);
        if (fd >= 0) { ssize_t k = read(fd, head, sizeof head - 1); close(fd); if (k > 0) head[k] = 0; }
        if (head[0] == '#' && head[1] == '!') {
            strtok(head, "\r\n");
            Words w = {0};
            for (char *t = strtok(head + 2, " "); t; t = strtok(NULL, " ")) if (!(w.n == 0 && !strcmp(t, "/usr/bin/env"))) add_word(&w, strdup(t));
            for (int i = 0; i < n; i++) add_word(&w, v[i]);
            rc = posix_spawnp(&pid, w.v[0], &fa, NULL, w.v, environ);
        } else rc = posix_spawn(&pid, v[0], &fa, NULL, v, environ);
    } else {
        const char *s = getenv("PATH");
        for (; s && *s && rc == ENOENT;) {
            const char *e = strchr(s, ':');
            snprintf(path, sizeof path, "%.*s/%s", (int)(e ? e - s : (long)strlen(s)), s, v[0]);
            if (!access(path, F_OK)) rc = posix_spawn(&pid, path, &fa, NULL, v, environ);
            s = e ? e + 1 : NULL;
        }
        if (rc == ENOENT) rc = posix_spawnp(&pid, v[0], &fa, NULL, v, environ);
    }
    posix_spawn_file_actions_destroy(&fa);
    if (rc) { say(io.err, "%s: %s\n", v[0], rc == ENOENT ? "not found" : strerror(rc)); return 127; }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
static int is(Toks *t, const char *s) { return t->at < t->n && !strcmp(t->t[t->at].s, s); }
static int is_assign(const char *s) {
    if (!isalpha((unsigned char)*s) && *s != '_') return 0;
    while (isalnum((unsigned char)*s) || *s == '_') s++;
    return *s == '=';
}
static int list(Toks *t, Io io, int go, const char *const *ends);
static int redirect(Toks *t, Io *io, int go, int *opened, int *nopened) { /* 1 took one, -1 failed */
    static const char *const ops[] = {">", "1>", ">>", "2>", "2>>", "&>", "<", NULL};
    if (t->at >= t->n || !t->t[t->at].op) return 0;
    const char *o = t->t[t->at].s;
    if (!strcmp(o, "2>&1")) { io->err = io->out; t->at++; return 1; }
    if (!strcmp(o, "1>&2") || !strcmp(o, ">&2")) { io->out = io->err; t->at++; return 1; }
    for (int i = 0; ops[i]; i++) {
        if (strcmp(o, ops[i])) continue;
        t->at++;
        if (t->at >= t->n) return -1;
        char *p = go ? expand1(t->t[t->at].s) : NULL;
        t->at++;
        if (!go) return 1;
        int fd = open(p, *o == '<' ? O_RDONLY : O_WRONLY | O_CREAT | (strstr(o, ">>") ? O_APPEND : O_TRUNC), 0666);
        if (fd < 0) { fail(*io, "sh", p); return -1; }
        if (*nopened < 16) opened[(*nopened)++] = fd;
        if (*o == '<') io->in = fd;
        else { if (*o != '2') io->out = fd; if (*o == '2' || *o == '&') io->err = fd; }
        return 1;
    }
    return 0;
}
static void skip_nl(Toks *t) { while (is(t, "\n") || is(t, ";")) t->at++; }
static void need(Toks *t, const char *s) { if (is(t, s)) t->at++; }
static int command(Toks *t, Io io, int go) {
    int opened[16], nopened = 0, rc = 0;
#define TAIL while ((r = redirect(t, &io, 0, opened, &nopened)) > 0) {}
    int r;
    if (is(t, "if")) {
        static const char *const a[] = {"then", NULL}, *const b[] = {"elif", "else", "fi", NULL};
        t->at++;
        int was = e_flag, done = 0;
        e_flag = 0;
        int c = list(t, io, go, a);
        e_flag = was;
        need(t, "then");
        if (go && c == 0) { rc = list(t, io, 1, b); done = 1; } else list(t, io, 0, b);
        while (is(t, "elif")) {
            t->at++;
            e_flag = 0;
            c = list(t, io, go && !done, a);
            e_flag = was;
            need(t, "then");
            if (go && !done && c == 0) { rc = list(t, io, 1, b); done = 1; } else list(t, io, 0, b);
        }
        if (is(t, "else")) { t->at++; if (go && !done) rc = list(t, io, 1, b); else list(t, io, 0, b); }
        need(t, "fi");
        TAIL
        return rc;
    }
    if (is(t, "for") || is(t, "while") || is(t, "until")) {
        static const char *const d[] = {"do", NULL}, *const e[] = {"done", NULL};
        int isfor = is(t, "for"), until = is(t, "until");
        t->at++;
        Words w = {0};
        const char *name = "";
        int cond = t->at;
        if (isfor) {
            name = t->at < t->n ? t->t[t->at++].s : "";
            if (is(t, "in")) { t->at++; while (t->at < t->n && !t->t[t->at].op) { if (go) expand(t->t[t->at].s, &w, 1); t->at++; } }
            else for (int i = 1; i < npos; i++) add_word(&w, pos[i]);
            skip_nl(t);
        }
        for (int i = 0;; i++) {
            int more = go;
            if (isfor) { more = go && i < w.n; if (more) setenv(name, w.v[i], 1); }
            else { t->at = cond; int was = e_flag; e_flag = 0; int c = list(t, io, go, d); e_flag = was; more = go && (until ? c != 0 : c == 0); }
            int body = t->at;
            need(t, "do");
            int x = list(t, io, more, e);
            if (more) rc = x;
            need(t, "done");
            int after = t->at;
            if (loop_go == 1) { loop_go = 0; more = 0; list((t->at = body, need(t, "do"), t), io, 0, e); need(t, "done"); after = t->at; }
            else if (loop_go == 2) { loop_go = 0; list((t->at = body, need(t, "do"), t), io, 0, e); need(t, "done"); after = t->at; }
            if (!more || quitting) { t->at = after; break; }
            if (isfor) t->at = body;
        }
        TAIL
        return rc;
    }
    if (is(t, "{") || is(t, "(")) {
        int sub = is(t, "(");
        static const char *const a[] = {"}", NULL}, *const b[] = {")", NULL};
        t->at++;
        /* Where it writes comes after it. */
        int start = t->at;
        list(t, io, 0, sub ? b : a);
        need(t, sub ? ")" : "}");
        while ((r = redirect(t, &io, go, opened, &nopened)) > 0) {}
        int after = t->at;
        if (go && r >= 0) {
            char p[PATH_MAX];
            getcwd(p, sizeof p);
            t->at = start;
            rc = list(t, io, 1, sub ? b : a);
            if (sub) { chdir(p); quitting = 0; }
        }
        t->at = after;
        for (int i = 0; i < nopened; i++) close(opened[i]);
        return r < 0 ? 1 : rc;
    }
    if (is(t, "!") ) { t->at++; return !command(t, io, go); }
    Words w = {0}, set = {0};
    while (t->at < t->n) {
        r = redirect(t, &io, go, opened, &nopened);
        if (r < 0) { go = 0; rc = 1; continue; }
        if (r) continue;
        if (t->t[t->at].op) break;
        const char *s = t->t[t->at++].s;
        if (!go) continue;
        if (!w.n && is_assign(s)) { const char *e = strchr(s, '='); char *v = expand1(e + 1), *pair; asprintf(&pair, "%.*s=%s", (int)(e - s), s, v); add_word(&set, pair); }
        else expand(s, &w, 1);
    }
    if (go) {
        if (w.n && (!strcmp(w.v[0], "env") || !strcmp(w.v[0], "exec") || !strcmp(w.v[0], "command") || !strcmp(w.v[0], "nohup") || !strcmp(w.v[0], "time")) && w.n > 1 && strcmp(w.v[1], "-v")) {
            w.v++, w.n--;
            while (w.n && is_assign(w.v[0])) add_word(&set, *w.v++), w.n--;
        }
        char *old[64];
        for (int i = 0; i < set.n; i++) {
            char *e = strchr(set.v[i], '=');
            *e = 0;
            if (i < 64) { char *o = getenv(set.v[i]); old[i] = o ? strdup(o) : NULL; }
            setenv(set.v[i], e + 1, 1);
        }
        if (x_flag && w.n) { say(io.err, "+"); for (int i = 0; i < w.n; i++) say(io.err, " %s", w.v[i]); say(io.err, "\n"); }
        if (w.n) {
            const char *base = strrchr(w.v[0], '/');
            if (!strcmp(base ? base + 1 : w.v[0], "ar")) rc = ar(w.n, w.v, io);
            else if (!builtin(w.n, w.v, io, &rc)) rc = spawn(w.n, w.v, io);
            for (int i = 0; i < set.n && i < 64; i++) { if (old[i]) setenv(set.v[i], old[i], 1); else unsetenv(set.v[i]); }
        }
    }
    for (int i = 0; i < nopened; i++) close(opened[i]);
    return rc;
}
static int pipeline(Toks *t, Io io, int go) {
    int rc = 0, in = io.in, first = 1;
    for (;;) {
        int start = t->at;
        command(t, io, 0); /* where it ends */
        int more = is(t, "|");
        if (go) {
            t->at = start;
            Io x = io;
            x.in = in;
            char path[PATH_MAX];
            if (more) {
                snprintf(path, sizeof path, "%s/pipe.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
                x.out = mkstemp(path);
                unlink(path);
            }
            rc = command(t, x, 1);
            if (!first) close(in);
            if (more) { lseek(x.out, 0, SEEK_SET); in = x.out; }
        }
        first = 0;
        if (!more) break;
        t->at++;
        while (is(t, "\n")) t->at++;
    }
    if (go) last = rc;
    return rc;
}
static int list(Toks *t, Io io, int go, const char *const *ends) {
    int rc = 0;
    for (;;) {
        skip_nl(t);
        if (t->at >= t->n) return rc;
        for (int i = 0; ends && ends[i]; i++) if (is(t, ends[i])) return rc;
        if (!ends && is(t, ")")) { t->at++; continue; }
        int was = t->at, run = go && !quitting && !loop_go, chained = 0;
        int x = pipeline(t, io, run);
        if (run) rc = x;
        while (is(t, "&&") || is(t, "||")) {
            chained = is(t, "&&") && rc != 0; /* a failure before && does not end the script */
            int yes = is(t, "&&") ? rc == 0 : rc != 0;
            t->at++;
            while (is(t, "\n")) t->at++;
            run = go && !quitting && !loop_go && yes;
            x = pipeline(t, io, run);
            if (run) rc = x;
        }
        if (go && !quitting && e_flag && rc && !chained) quitting = 1;
        if (is(t, "&")) t->at++;
        if (t->at == was) t->at++;
    }
}
static int run_text(const char *text, Io io) {
    Toks t = lex(text);
    return list(&t, io, 1, NULL);
}

int main(int argc, char **argv) {
    const char *cmd = NULL, *me = strrchr(argv[0], '/');
    if (!strcmp(me ? me + 1 : argv[0], "ar")) return ar(argc, argv, (Io){0, 1, 2});
    me = me ? me + 1 : argv[0];
    if (strcmp(me, "sh") && strcmp(me, "bash") && strcmp(me, "zsh") && strcmp(me, "dash") && *me != '-') { /* by the name of what is built in */
        int rc = 0;
        if (builtin(argc, argv, (Io){0, 1, 2}, &rc)) return rc;
    }
    int i = 1;
    for (; i < argc && (argv[i][0] == '-' || argv[i][0] == '+') && argv[i][1]; i++) {
        if (strchr(argv[i], 'e')) e_flag = 1;
        if (strchr(argv[i], 'x')) x_flag = 1;
        if (argv[i][0] == '-' && strchr(argv[i], 'c')) { cmd = i + 1 < argc ? argv[++i] : ""; i++; break; }
    }
    Buf b = {0};
    put(&b, "", 0);
    if (cmd) { put(&b, cmd, strlen(cmd)); pos = argv + i, npos = argc - i; }
    else {
        int fd = i < argc ? open(argv[i], O_RDONLY) : 0;
        if (fd < 0) { say(2, "sh: %s: %s\n", argv[i], strerror(errno)); return 127; }
        char t[4096];
        ssize_t k;
        while ((k = read(fd, t, sizeof t)) > 0) put(&b, t, (size_t)k);
        pos = argv + i, npos = argc - i;
    }
    return run_text(b.p, (Io){0, 1, 2}) & 255;
}
