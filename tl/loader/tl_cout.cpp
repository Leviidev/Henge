/* std::cout, cerr, clog and cin for the tools of tl_tool.h, for each namespace its own: the system's write to the app's
   standard files. What is written goes to the run of the thread that writes it. */
#include <cstring>
#include <iostream>
#include <streambuf>

extern "C" void tl_tool_stream_write(int fd, const char *p, size_t n);
extern "C" long tl_tool_stream_read(char *p, size_t n);

namespace {
struct Out : std::streambuf {
    int fd;
    explicit Out(int f) : fd(f) {}
    int overflow(int c) override {
        char b = (char)c;
        if (c != traits_type::eof()) tl_tool_stream_write(fd, &b, 1);
        return c == traits_type::eof() ? 0 : c;
    }
    std::streamsize xsputn(const char *p, std::streamsize n) override {
        tl_tool_stream_write(fd, p, (size_t)n);
        return n;
    }
};
struct In : std::streambuf { /* one character at a time: the rest of the input may be another run's */
    char one = 0;
    int underflow() override {
        if (tl_tool_stream_read(&one, 1) != 1) return traits_type::eof();
        setg(&one, &one, &one + 1);
        return (unsigned char)one;
    }
};
}

namespace {
struct Set {
    Out o{1}, e{2};
    In i;
    std::ostream cout{&o}, cerr{&e}, clog{&e};
    std::istream cin{&i};
};
Set *sets[256];
}

extern "C" void *tl_tool_stream(int ns, const char *sym) {
    if (ns < 0 || ns >= 256) return nullptr;
    bool out = !strcmp(sym, "__ZNSt3__14coutE"), err = !strcmp(sym, "__ZNSt3__14cerrE"), log = !strcmp(sym, "__ZNSt3__14clogE"), in = !strcmp(sym, "__ZNSt3__13cinE");
    if (!out && !err && !log && !in) return nullptr;
    if (!sets[ns]) sets[ns] = new Set;
    return out ? (void *)&sets[ns]->cout : err ? (void *)&sets[ns]->cerr : log ? (void *)&sets[ns]->clog : (void *)&sets[ns]->cin;
}
/* As they are at a program's start. */
extern "C" void tl_tool_stream_reset(int ns) {
    Set *s = ns >= 0 && ns < 256 ? sets[ns] : nullptr;
    if (!s) return;
    static const std::ios plain(nullptr);
    for (std::ostream *o : {&s->cout, &s->cerr, &s->clog}) o->copyfmt(plain), o->clear();
    s->cin.copyfmt(plain);
    s->cin.clear();
    s->cin.rdbuf(&s->i);
}
