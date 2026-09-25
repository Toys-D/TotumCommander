/* config.h — generated for macOS (Darwin) build of libntfs-3g */

#ifndef _NTFS3G_CONFIG_H
#define _NTFS3G_CONFIG_H

/* Standard C headers — all present on macOS */
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDARG_H 1
#define HAVE_STDDEF_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_LIMITS_H 1
#define HAVE_CTYPE_H 1
#define HAVE_WCHAR_H 1
#define HAVE_ERRNO_H 1
#define HAVE_LOCALE_H 1
#define HAVE_TIME_H 1

/* POSIX headers — present on macOS */
#define HAVE_UNISTD_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYSLOG_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_MOUNT_H 1
#define HAVE_SYS_XATTR_H 1
#define HAVE_SYS_DISK_H 1

/* macOS-specific endian header */
#define HAVE_MACHINE_ENDIAN_H 1
/* Linux-only — NOT on macOS */
/* #undef HAVE_ENDIAN_H */
/* #undef HAVE_SYS_ENDIAN_H */
/* #undef HAVE_BYTESWAP_H */
/* #undef HAVE_SYS_BYTEORDER_H */

/* Functions available on macOS */
#define HAVE_CLOCK_GETTIME 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_FFS 1
#define HAVE_MBSINIT 1
#define HAVE_REALPATH 1
#define HAVE_SETXATTR 1
#define HAVE_STRSEP 1
#define HAVE_DAEMON 1

/* Linux-only headers/features — NOT on macOS */
/* #undef HAVE_LINUX_FD_H */
/* #undef HAVE_LINUX_FS_H */
/* #undef HAVE_LINUX_HDREG_H */
/* #undef HAVE_MNTENT_H */
/* #undef HAVE_HASMNTOPT */
/* #undef HAVE_SYS_SYSMACROS_H */
/* #undef HAVE_WINDOWS_H */

/* xattr API: macOS uses different signature than Linux */
#define XATTR_SYSCALL_ARGS

/* Package version */
#define PACKAGE "ntfs-3g"
#define VERSION "2022.10.3"
#define PACKAGE_VERSION "2022.10.3"

#endif /* _NTFS3G_CONFIG_H */
