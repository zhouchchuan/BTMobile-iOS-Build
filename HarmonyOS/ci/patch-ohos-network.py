"""Apply only the HarmonyOS network adapter to pinned libtorrent source.

The Linux host test path is unchanged. Repeated cached CI runs are idempotent.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
config = root / 'include/libtorrent/config.hpp'
text = config.read_text()
marker = '// BTMOBILE_OHOS_NETWORK_V1'
if marker not in text:
    anchor = '#define TORRENT_USE_NETLINK 1\n#define TORRENT_USE_IFADDRS 0\n#define TORRENT_USE_IFCONF 1'
    assert text.count(anchor) == 1, 'Pinned libtorrent config changed; review adapter'
    text = text.replace(anchor, marker + '\n#if defined(BTMOBILE_OHOS)\n#define TORRENT_USE_NETLINK 0\n#else\n#define TORRENT_USE_NETLINK 1\n#endif\n#define TORRENT_USE_IFADDRS 0\n#define TORRENT_USE_IFCONF 1')
    config.write_text(text)

source = root / 'src/enum_net.cpp'
text = source.read_text()
if marker not in text:
    anchor = '#include "libtorrent/config.hpp"'
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + '\n' + marker + '\n#if defined(BTMOBILE_OHOS)\n#include "ohos_network.hpp"\n#endif')
    for name, method in [('enum_net_interfaces', 'interfaces'), ('enum_routes', 'routes')]:
        pattern = r'(\tstd::vector<[^\n]+> ' + name + r'\(io_context& ios, error_code& ec\)\n\t\{\n)(.*?)(\n\t\})'
        text, count = re.subn(pattern, lambda m: m[1] + '#if defined(BTMOBILE_OHOS)\n\t\tTORRENT_UNUSED(ios);\n\t\treturn btmobile_ohos::' + method + '(ec);\n#else\n' + m[2] + '\n#endif' + m[3], text, flags=re.S)
        assert count == 1, 'Pinned libtorrent function changed: ' + name
    source.write_text(text)
print('HarmonyOS NetworkKit adapter applied; Linux host path preserved')
