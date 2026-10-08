#include "../entry/src/main/cpp/range.hpp"
#include <cassert>
#include <iostream>
int main() {
    assert(parseRange("",100)->end == 99);
    assert(parseRange("bytes=10-19",100)->start == 10);
    assert(parseRange("bytes=90-200",100)->end == 99);
    assert(parseRange("bytes=-20",100)->start == 80);
    assert(parseRange("bytes=5-",100)->end == 99);
    for (auto s : {"bytes=-0", "bytes=100-", "bytes=20-10", "bytes=1-2,4-5", "bytes=99999999999999999999-", "bytes=a-3"}) assert(!parseRange(s,100));
    assert(!parseRange("",0));
    for (auto s : {"../escape", "/root", "C:/test", "a/../../bad", "a\\..\\bad"}) assert(!safeArchivePath(s));
    assert(safeArchivePath("字幕/测试.srt"));
    std::cout << "byte ranges and archive traversal tests passed\n";
}
