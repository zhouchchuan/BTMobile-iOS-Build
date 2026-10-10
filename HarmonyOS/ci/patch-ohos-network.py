"""Apply only the HarmonyOS network adapter to pinned libtorrent source.

The Linux host test path is unchanged. Repeated cached CI runs are idempotent.
"""
import pathlib
import subprocess
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
source_marker = '// BTMOBILE_OHOS_NETWORK_V2'
if marker in text:
    # V1 wrapped a whole function by indentation; upstream has same-indented
    # platform branches. Migrate only our cached source from the pinned object.
    text = subprocess.check_output(['git', '-C', str(root), 'show',
        '75a08775ba32bdb62157f9e49a786ecdd9f0a0fa:src/enum_net.cpp'], text=True)
if source_marker not in text:
    anchor = '#include "libtorrent/config.hpp"'
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + '\n' + source_marker + '\n#if defined(BTMOBILE_OHOS)\n#include "ohos_network.hpp"\n#endif')
    for anchor, method in [('#if defined TORRENT_BUILD_SIMULATOR\n\n\t\tstd::vector<address> ips', 'interfaces'),
                           ('#ifdef TORRENT_BUILD_SIMULATOR\n\n\t\tTORRENT_UNUSED(ec);', 'routes')]:
        assert text.count(anchor) == 1, 'Pinned libtorrent platform anchor changed: ' + method
        tail = anchor.split('\n', 1)[1]
        text = text.replace(anchor, '#if defined(BTMOBILE_OHOS)\n\t\treturn btmobile_ohos::' + method + '(ec);\n#elif defined TORRENT_BUILD_SIMULATOR\n' + tail)
    source.write_text(text)
print('HarmonyOS NetworkKit adapter applied; Linux host path preserved')
