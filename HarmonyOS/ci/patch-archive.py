"""Constrain 7-Zip's secondary-volume requests to regular sibling files."""
import pathlib
import sys

source = pathlib.Path(sys.argv[1]) / 'src/internal/opencallback.cpp'
text = source.read_text(encoding='utf-8')
old = '''            streamPath = streamPath.parent_path();
            streamPath.append( name );
            std::error_code error;
            const auto streamStatus = fs::status( streamPath, error );'''
new = '''            // BTMOBILE_VOLUME_SANDBOX: an archive cannot request arbitrary local files.
            const fs::path requested( name );
            if ( requested.is_absolute() || requested.has_parent_path() ||
                 requested.filename() == "." || requested.filename() == ".." ) return E_ACCESSDENIED;
            streamPath = streamPath.parent_path() / requested;
            std::error_code error;
            const auto streamStatus = fs::symlink_status( streamPath, error );
            if ( !error && !fs::is_regular_file( streamStatus ) ) return E_ACCESSDENIED;'''
if 'BTMOBILE_VOLUME_SANDBOX' not in text:
    assert text.count(old) == 1, 'Upstream volume callback changed; review before applying'
    source.write_text(text.replace(old, new), encoding='utf-8')
