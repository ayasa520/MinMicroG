#!/sbin/sh

# Minimal MicroG installer
# By FriendlyNeighborhoodShane
# Based on work by osm0sis @ xda-developers (Thanks!)
#
# Copyright 2018-2020 FriendlyNeighborhoodShane
# Distributed under the terms of the GNU GPL v3

exec 3>&1;
exec 1>&2;

SKIPUNZIP=1

$BOOTMODE || mount -o bind /dev/urandom /dev/random;

select_word() {
    select_term="$1";
    while read -r select_line; do
        select_current=0;
        select_found="";
        for select_each in $select_line; do
            select_current="$(( select_current + 1 ))";
            [ "$select_current" = "$select_term" ] && { select_found="yes"; break; }
        done;
        [ "$select_found" = "yes" ] && echo "$select_each";
    done;
}
file_getprop() {
    grep "^$2=" "$1" | head -n1 | select_word 1 | cut -d= -f2;
}

umountparts="";
cleanup() {
    rm -rf "$FILEDIR" "$BBDIR";
    $BOOTMODE || {
        for part in $umountparts; do
            umount "$part";
        done;
    }
    sync;
}

abort() {
    ui_print " ";
    ui_print "!!! FATAL ERROR: $1";
    ui_print " ";
    ui_print "Stopping installation and Uninstalling...";
    uninstall_pack;
    cleanup;
    ui_print " ";
    ui_print "Installation failed!";
    ui_print " ";
    exit 1;
}

ismntpoint() {
    mount | grep -q " on $1 ";
}

fstab_getmount() {
    grep -v "^#" /etc/recovery.fstab | grep "[[:blank:]]$1[[:blank:]]" | tail -n1 | tr -s "[:blank:]" " " | cut -d" " -f1;
}

find_block() {
    dynamicpart="$(getprop ro.boot.dynamic_partitions)";
    [ "$dynamicpart" = "true" ] || dynamicpart="false";
    [ "$dynamicpart" = "true" ] && blkpath="/dev/block/mapper" || {
        blkpath="/dev/block/by-name";
        [ -d "$blkpath" ] || blkpath="/dev/block/bootdevice/by-name";
    }
    blkabslot="$(getprop ro.boot.slot_suffix)";
    for name in "$@"; do
        blkmount="$(fstab_getmount "$name")";
        [ "$blkmount" ] && blkmountexists="true" || blkmountexists="false";
        case "$dynamicpart-$blkmountexists" in
            true-true)
                blkdev="${blkpath}/${blkmount}${blkabslot}";
            ;;
            false-true)
                blkdev="${blkmount}${blkabslot}";
            ;;
            true-false|false-false)
                blkdev="${blkpath}/${name}${blkabslot}";
            ;;
        esac;
        [ -b "$blkdev" ] && {
            echo "$blkdev";
            return;
        }
    done;
}


$BOOTMODE || {
    log " ";
    log "Mounting early";
    for part in "/system" "/system_root"; do
        [ -e "$part" ] || continue;
        mount -o ro "$part";
        log "Mountpoint $part mounted (auto)";
        umountparts="$umountparts $part";
    done;
    sysblk="$(find_block /system_root /system /)";
    [ "$sysblk" ] && {
        for part in "/mnt/system"; do
            mkdir -p "$part";
            mount -o ro "$sysblk" "$part";
            umountparts="$umountparts $part";
            log "Mountpoint $part mounted (manual $sysblk)";
        done;
    }
    mount /data;
    umountparts="$umountparts /data";
}
[ -e "/system/build.prop" ] && { SYSROOT="/"; SYSROOTPART="/system"; };
[ -e "/system/system/build.prop" ] && { SYSROOT="/system"; SYSROOTPART="/system"; };
[ -e "/system_root/system/build.prop" ] && { SYSROOT="/system_root"; SYSROOTPART="/system_root"; };
[ -e "/mnt/system/system/build.prop" ] && { SYSROOT="/mnt/system"; SYSROOTPART="/mnt/system"; };
[ -f "$SYSROOT/system/build.prop" ] || abort "Could not find a ROM!";

# BBDIR="/tmp/busybox";
$BOOTMODE || {
    for bb in /data/adb/magisk/busybox; do
        [ -f "$bb" ] && MAGISKBB="$bb";
    done;
    [ "$MAGISKBB" ] && {
        ui_print " ";
        ui_print "Setting up busybox...";
        mkdir -p "$BBDIR";
        "$MAGISKBB" --install -s "$BBDIR/";
        export PATH="$BBDIR:$PATH";
        log "Shell path set to $PATH";
    }
}

for bin in chcon chmod chown cp cut df du echo find grep head mkdir mount ps rm sed tail touch tr umount unzip; do
    command -v "$bin" >/dev/null || abort "No $bin available";
done;

# $BOOTMODE && FILEDIR="/dev/tmp/$MODID" || FILEDIR="/tmp/$MODNAME";
FILEDIR="$TMPDIR/$MODID"
TMPLIBDIR="$FILEDIR/tmplibdir";

$BOOTMODE && FORCESYS=false;
case "$(basename "$ZIPFILE" | tr 'A-Z' 'a-z')" in
    *system*)
        FORCESYS=true;
        ui_print " ";
        ui_print "WARNING: Forcing a system action!";
    ;;
esac;
case "$(basename "$ZIPFILE" | tr 'A-Z' 'a-z')" in
    *uninstall*)
        ACTION=uninstallation;
    ;;
    *)
        ACTION=installation;
    ;;
esac;

api_level_arch_detect;
if [ "$ABI32" = "x86" ]; then
    LIBARCHES="x86 armeabi-v7a armeabi"
    if [ "$IS64BIT" = "true" ]; then
        LIBARCHES="x86_64 $LIBARCHES"
    fi
elif [ "$ABI32" = "armeabi-v7a" ]; then
    LIBARCHES="armeabi-v7a armeabi"
    if [ "$IS64BIT" = "true" ]; then
        LIBARCHES="arm64-v8a $LIBARCHES"
    fi
elif [ "$ABI32" = "mips" ]; then
    LIBARCHES="mips"
    if [ "$IS64BIT" = "true" ]; then
        LIBARCHES="mips64 $LIBARCHES"
    fi
fi

# sdk="$(file_getprop $SYSROOT/system/build.prop ro.build.version.sdk)";
[ "$API" ] || abort "Could not find SDK";
[ "$API" -gt 0 ] || abort "Could not recognise SDK: $API";

sizecheck() {
    for realsizeobject in $1; do
        sizeobject="$realsizeobject";
        break;
    done;
    [ -e "$sizeobject" ] || { echo 0; return 0; }
    objectsize="$(du -s "$sizeobject" | select_word 1)";
    libsize=0;
    case "$sizeobject" in
        *.apk)
            apkunzip="$(unzip -l "$sizeobject" "lib/*/lib*.so")";
            if echo "$apkunzip" | grep -q "lib/.*/lib.*.so"; then
                for archlib in $LIBARCHES; do
                    if echo "$apkunzip" | grep -q "lib/$archlib/lib.*.so"; then
                        libsizeb=0;
                        for entry in $(unzip -l "$sizeobject" | grep "lib/$archlib/lib.*.so" | select_word 1); do
                            libsizeb="$(( libsizeb + entry ))";
                        done;
                        libsize="$(( libsizeb / 1024 + 1 ))";
                        break;
                    fi;
                done;
            fi;
        ;;
    esac;
    echo "$(( objectsize + libsize ))";
}

remove() {
    removalobject="$1";
    if [ "$API" -lt 21 ]; then
        [ "$(basename "$(dirname "$removalobject")").apk" = "$(basename "$removalobject")" ] && {
            removalobject="$(dirname "$(dirname "$removalobject")")/$(basename "$removalobject")";
        }
    fi;
    [ "$(basename "$(dirname "$removalobject")").apk" = "$(basename "$removalobject")" ] && {
        removalobject="$(dirname "$removalobject")";
    }
    [ -e "$removalobject" ] || return 0;
    rm -rf "$removalobject" || { log "ERROR: Could not remove ($removalobject)"; return 1; }
    if [ -e "$removalobject" ]; then
        log "ERROR: Could not remove ($removalobject)";
        return 1;
    else
        log "REMOVER: Object removed ($removalobject)";
    fi;
}

debloat() {
    debloatobject="$1";
    debloatingobject="$2";
    if [ "$API" -lt 21 ]; then
        [ "$(basename "$(dirname "$debloatobject")").apk" = "$(basename "$debloatobject")" ] && {
            debloatobject="$(dirname "$(dirname "$debloatobject")")/$(basename "$debloatobject")";
            debloatingobject="$(dirname "$(dirname "$debloatingobject")")/$(basename "$debloatingobject")";
        }
    fi;
    [ "$(basename "$(dirname "$debloatobject")").apk" = "$(basename "$debloatobject")" ] && debloatobject="$(dirname "$debloatobject")";
    [ -e "$debloatobject" ] || return 0;
    mkdir -p "$(dirname "$debloatingobject")";
    if [ "$(basename "$(dirname "$debloatingobject")").apk" = "$(basename "$debloatingobject")" ]; then
        if touch "$(dirname "$debloatingobject")/.replace"; then
            log "DEBLOATER: Object directory debloated ($debloatobject)";
        else
            log "ERROR: Could not create replace file for object $debloatobject";
            return 1;
        fi;
        elif [ -d "$debloatobject" ]; then
        mkdir -p "$debloatingobject";
        if touch "$debloatingobject/.replace"; then
            log "DEBLOATER: directory debloated ($debloatobject)";
        else
            log "ERROR: Could not create replace file for directory $debloatobject";
            return 1;
        fi;
    else
        if echo "# This is a dummy for debloating" > "$debloatingobject"; then
            log "DEBLOATER: Object dummy debloated ($debloatobject)";
        else
            log "ERROR: Could not create dummy file for $debloatobject";
            return 1;
        fi;
    fi;
}

uninstall() {
    uninstallobject="$1";
    if [ "$API" -lt 21 ]; then
        [ "$(basename "$(dirname "$uninstallobject")").apk" = "$(basename "$uninstallobject")" ] && uninstallobject="$(dirname "$(dirname "$uninstallobject")")/$(basename "$uninstallobject")";
    fi;
    [ "$(basename "$(dirname "$uninstallobject")").apk" = "$(basename "$uninstallobject")" ] && uninstallobject="$(dirname "$uninstallobject")";
    [ -e "$uninstallobject" ] || return 0;
    rm -rf "$uninstallobject" || {
        log "ERROR: Object not uninstalled ($uninstallobject)";
        return 1;
    }
    if [ -e "$uninstallobject" ]; then
        log "ERROR: Object not uninstalled ($uninstallobject)";
        return 1;
    else
        log "UNINSTALLER: Object uninstalled ($uninstallobject)";
    fi;
}

install_dest() {
    for realobject in $1; do
        object="$realobject";
        break;
    done;
    destobject="$2";
    [ -e "$object" ] || { log "ERROR: Object not found ($object)"; return 1; }
    if [ "$API" -lt 21 ]; then
        [ "$(basename "$(dirname "$destobject")").apk" = "$(basename "$destobject")" ] && destobject="$(dirname "$(dirname "$destobject")")/$(basename "$destobject")";
    fi;
    mkdir -p "$(dirname "$destobject")";
    cp -rf "$object" "$destobject" || abort "Could not install $destobject";
    if [ -e "$destobject" ]; then
        log "INSTALLER: Object installed ($object to $destobject)";
    else
        abort "Could not install $destobject";
    fi;
    case "$destobject" in
        *.apk)
            install_lib "$destobject";
        ;;
    esac;
}

install_lib() {
    libobject="$1";
    mkdir -p "$TMPLIBDIR";
    unzipout="$(unzip -l "$libobject" "lib/*/lib*.so")";
    echo "$unzipout" | grep -q "lib/.*/lib.*.so" || return 0;
    for archlib in $LIBARCHES; do
        if echo "$unzipout" | grep -q "lib/$archlib/lib.*.so"; then
            case "$archlib" in
                *arm64*)
                    log "INSTALLER: Installing arm64 libs ($libobject)";
                    libdir=lib64;
                    libarch=arm64;
                ;;
                *arm*)
                    log "INSTALLER: Installing arm libs ($libobject)";
                    libdir=lib;
                    libarch=arm;
                ;;
                *x86_64*)
                    log "INSTALLER: Installing x86_64 libs ($libobject)";
                    libdir=lib64;
                    libarch=x86_64;
                ;;
                *x86*)
                    log "INSTALLER: Installing x86 libs ($libobject)";
                    libdir=lib;
                    libarch=x86;
                ;;
                *mips64*)
                    log "INSTALLER: Installing mips64 libs ($libobject)";
                    libdir=lib64;
                    libarch=mips64;
                ;;
                *mips*)
                    log "INSTALLER: Installing mips libs ($libobject)";
                    libdir=lib;
                    libarch=mips;
                ;;
            esac;
            if [ "$API" -lt 21 ]; then
                libdest="$(dirname "$(dirname "$libobject")")/$libdir";
            else
                libdest="$(dirname "$libobject")/lib/$libarch";
            fi;
            unzip -oq "$libobject" "lib/$archlib/lib*.so" -d "$TMPLIBDIR";
            mkdir -p "$libdest";
            for lib in "$TMPLIBDIR/lib/$archlib"/lib*.so; do
                cp -rf "$lib" "$libdest/$(basename "$lib")" || abort "Could not Install $lib for $libobject";
                if [ -f "$libdest/$(basename "$lib")" ]; then
                    log "INSTALLER: Installed library ($lib to $libdest)";
                else
                    abort "Could not Install $lib for $libobject";
                fi;
            done;
            break;
        fi;
    done;
    rm -rf "$TMPLIBDIR";
}

sizecheck_pack() {
    packsize=0;
    for thing in defconf $stuff; do
        [ "$thing" ] && packsize="$(( packsize + $(sizecheck "$FILEDIR/$thing") ))";
    done;
    for thing in $stuff_arch; do
        [ "$thing" ] && packsize="$(( packsize + $(sizecheck "$FILEDIR/$(dirname "$thing")/*-$ARCH-*/$(basename "$thing")") ))";
    done;
    for thing in $stuff_sdk; do
        [ "$thing" ] && packsize="$(( packsize + $(sizecheck "$FILEDIR/$(dirname "$thing")/*-$API-*/$(basename "$thing")") ))";
    done;
    for thing in $stuff_arch_sdk; do
        [ "$thing" ] && packsize="$(( packsize + $(sizecheck "$FILEDIR/$(dirname "$thing")/*-$ARCH-*-$API-*/$(basename "$thing")") ))";
    done;
    echo "$packsize";
}

uninstall_pack() {
    if [ "$MAGISK" = "true" ]; then
        rm -rf "$ROOT" || { log " "; log "Could not delete Magisk root ($ROOT)"; }
        elif [ "$MAGISK" = "false" ]; then
        for thing in $stuff_uninstall; do
            [ "$thing" ] && uninstall "$ROOT/$thing";
        done;
    fi;
}

perm() {
    uid="$1";
    gid="$2";
    dmod="$3";
    fmod="$4";
    permobject="$5";
    [ -e "$permobject" ] || return 0;
    chown -R "$uid:$gid" "$permobject" || chown -R "$uid.$gid" "$permobject";
    find "$permobject" -type d -exec chmod "$dmod" {} +;
    find "$permobject" -type f -exec chmod "$fmod" {} +;
}

rm -rf "$FILEDIR";
mkdir -p "$FILEDIR";
unzip -o "$ZIPFILE" "defconf" -d "$FILEDIR/";
echo "zip $ZIPFILE"
echo "ls $FILEDIR"
ls $FILEDIR
[ -f "$FILEDIR/defconf" ] || abort "Could not find a default config";
. "$FILEDIR/defconf" || abort "Could not execute default config";

# moddir="/data/media/0/$MODID";

# ui_print " ";
# ui_print "Package: $variant";
# ui_print "Version: $ver";
# ui_print "Release date: $date";
# ui_print " ";
# ui_print "Using architecture: $arch";
# ui_print "Using SDK level: $API";
# ui_print "Sysroot is on $SYSROOT";
# if [ "$API" -lt "$minsdk" ]; then
#   ui_print " ";
#   ui_print "WARNING: Using an old Android";
#   ui_print "Full compatibility not guaranteed";
# fi;

# ui_print " ";
ui_print "Mounting...";

if [ $MAGISK_VER ] && [ $MAGISK_VER_CODE ] && [ $FORCESYS = "false"  ];then
    # magisk mode
    MAGISK=true;
    ROOTPART="/data";
    ROOT=$MODPATH
    log "Using $MODULEROOT";
    
else
    # system mode
    ROOTPART="$SYSROOTPART";
    [ "$dynamicpart" = "true" ] && [ "$sysblk" ] && blockdev --setrw "$sysblk";
    mount -o rw,remount "$ROOTPART";
    mount -o rw,remount "$ROOTPART" "$ROOTPART";
    ROOT="$SYSROOT";
    MAGISK=false;
    log "Mounted $ROOTPART RW";
    
fi

if [ "$ACTION" = "installation" ]; then
    
    ui_print " ";
    ui_print "Extracting files...";
    mkdir -p "$FILEDIR";
    unzip -o "$ZIPFILE" -d "$FILEDIR" || abort "Could not unzip $ZIPFILE";
    
    pre_install_actions;
    
    ui_print " ";
    ui_print "Cleaning up...";
    log "Removing duplicates";
    uninstall_pack;
    log "Debloating";
    if [ "$MAGISK" = "true" ]; then
        for thing in $stuff_debloat $stuff_uninstall; do
            [ "$thing" ] && debloat "$SYSROOT/$thing" "$ROOT/$thing";
        done;
        elif [ "$MAGISK" = "false" ]; then
        for thing in $stuff_debloat; do
            [ "$thing" ] && remove "$SYSROOT/$thing";
        done;
    fi;
    
    ui_print " ";
    ui_print "Doing size checks...";
    packsizem="$(( $(sizecheck_pack) / 1024 + 1 ))";
    log "Pack size is $packsizem";
    diskfreem="$(( $(df -Pk "$ROOTPART" | tail -n 1 | select_word 4) / 1024 ))";
    log "Free space in $ROOTPART is $diskfreem";
    [ "$diskfreem" -gt "$packsizem" ] || abort "Not enough free space in your $ROOTPART!";
    
    ui_print " ";
    ui_print "Installing $MODID to $ROOT...";
    mkdir -p "$ROOT";
    
    log " ";
    log "Installing generic stuff";
    for thing in $stuff; do
        [ "$thing" ] && install_dest "$FILEDIR/$thing" "$ROOT/$thing";
    done;
    
    log " ";
    log "Installing Arch dependant stuff for $ARCH";
    for thing in $stuff_arch; do
        [ "$thing" ] && install_dest "$FILEDIR/$(dirname "$thing")/*-$ARCH-*/$(basename "$thing")" "$ROOT/$thing";
    done;
    
    log " ";
    log "Installing SDK dependant stuff for SDK $API";
    for thing in $stuff_sdk; do
        [ "$thing" ] && install_dest "$FILEDIR$(dirname "$thing")/*-$API-*/$(basename "$thing")" "$ROOT/$thing";
    done;
    
    log " ";
    log "Installing Arch and SDK dependant stuff for $ARCH and SDK $API";
    for thing in $stuff_arch_sdk; do
        if [ "$IS64BIT" = "true" ] && [ "$(basename "$(dirname "$thing")")" = "lib" ]; then
            # 32 bit libs for 64 bit arch
            [ "$thing" ] && install_dest "$FILEDIR/$(dirname "$thing")/*-$ABI32-*-$API-*/$(basename "$thing")" "$ROOT/$thing";
        else
            [ "$thing" ] && install_dest "$FILEDIR/$(dirname "$thing")/*-$ARCH-*-$API-*/$(basename "$thing")" "$ROOT/$thing";
        fi
    done;
    
    log " ";
    log "Executing other actions";
    if [ "$MAGISK" = "true" ]; then
        [ "$modprop" ] && {
            echo "$modprop" > "$ROOT/module.prop" || abort "Could not create module.prop in $ROOT";
        }
        touch "$ROOT/auto_mount" || abort "Could not create auto_mount in $ROOT";
        if $BOOTMODE; then
            MODMNT="$(dirname "$(dirname "$MODPATH")")/modules"  
            mkdir -p "$MODMNT/$MODID";
            touch "$MODMNT/$MODID/update" || abort "Could not create update in $MODMNT/$MODNAME";
            [ "$modprop" ] && {
                echo "$modprop" > "$MODMNT/$MODID/module.prop" || abort "Could not create module.prop in $MODMNT/$MODNAME";
            }
        fi;
    fi;
    
    ui_print " ";
    ui_print "Setting permissions...";
    if [ "$MAGISK" = "true" ]; then
        find "$ROOT" -maxdepth 1 -exec chmod 0755 {} +;
    fi;
    for thing in $stuff_perm; do
        case "$thing" in
            */bin*|*/xbin*)
                perm 0 2000 0755 0777 "$ROOT/$thing";
            ;;
            *)
                perm 0 0 0755 0644 "$ROOT/$thing";
            ;;
        esac;
        chcon -hR 'u:object_r:system_file:s0' "$ROOT/$thing";
    done;
    
    post_install_actions;
    
fi;

if [ "$ACTION" = "uninstallation" ]; then
    
    pre_uninstall_actions;
    
    ui_print " ";
    ui_print "Uninstalling $MODID from $ROOT...";
    uninstall_pack;
    
    post_uninstall_actions;
    
fi;

ui_print " ";
ui_print "Unmounting...";
cleanup;

ui_print " ";
ui_print "Done!";
ui_print " ";
exit 0;
