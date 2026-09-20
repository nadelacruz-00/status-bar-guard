#!/system/bin/sh
# Dump package/path data for the Status Bar Guard WebUI meta refresh.
D=/data/data/cn.com.omnimind.bot/workspace/statusbarguard-webui
mkdir -p $D
pm list packages -f 2>/dev/null | sed 's/^package://' | awk '{n=split($0,a,"="); pkg=a[n]; path=substr($0,1,length($0)-length(pkg)-1); printf "%s\t%s\n", pkg, path}' | sort > $D/pkg_paths_all.tsv
pm list packages -3 2>/dev/null | sed 's/^package://' | sort > $D/pkgs_user.txt
pm list packages -s 2>/dev/null | sed 's/^package://' | sort > $D/pkgs_system.txt
echo "dumped: $(wc -l < $D/pkg_paths_all.tsv) pkgs, $(wc -l < $D/pkgs_user.txt) user, $(wc -l < $D/pkgs_system.txt) system"
