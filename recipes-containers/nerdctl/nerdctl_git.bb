HOMEPAGE = "https://github.com/containerd/nerdctl"
SUMMARY =  "Docker-compatible CLI for containerd"
DESCRIPTION = "nerdctl: Docker-compatible CLI for containerd \
    "

DEPENDS = " \
    go-md2man \
    rsync-native \
    ${@bb.utils.filter('DISTRO_FEATURES', 'systemd', d)} \
"

# Specify the first two important SRCREVs as the format
SRCREV_FORMAT = "nerdcli_cgroups"
SRCREV_nerdcli = "832c4556e0b82789f687b70d1e394b892e035722"

SRC_URI = "git://github.com/containerd/nerdctl.git;name=nerdcli;branch=main;protocol=https;destsuffix=${GO_SRCURI_DESTSUFFIX}"

include src_uri.inc

# patches and config
SRC_URI += " \
            file://0001-Makefile-allow-external-specification-of-build-setti.patch \
           "

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://src/import/LICENSE;md5=3b83ef96387f14655fc854ddc3c6bd57"

GO_IMPORT = "import"

PV = "v2.1.3"

NERDCTL_PKG = "github.com/containerd/nerdctl"

BB_GIT_SHALLOW = "1"
BB_GIT_SHALLOW_DEPTH = "1"
BB_GENERATE_SHALLOW_TARBALLS = "1"

inherit go goarch
inherit systemd pkgconfig

# Set up Go working directory
GO_WORKDIR ?= "${GO_IMPORT}"
do_compile[dirs] += "${B}/src/${GO_WORKDIR}"

do_configure[noexec] = "1"

include module_cache_task.inc 

EXTRA_OEMAKE = " \
     PREFIX=${prefix} BINDIR=${bindir} LIBEXECDIR=${libexecdir} \
     ETCDIR=${sysconfdir} TMPFILESDIR=${nonarch_libdir}/tmpfiles.d \
     SYSTEMDDIR=${systemd_unitdir}/system USERSYSTEMDDIR=${systemd_unitdir}/user \
"

PACKAGECONFIG ?= ""

PIEFLAG = "${@bb.utils.contains('GOBUILDFLAGS', '-buildmode=pie', '-buildmode=pie', '', d)}"

do_compile() {
    	cd ${S}/src/import

	# Pass the needed cflags/ldflags so that cgo
	# can find the needed headers files and libraries
	export GOARCH=${TARGET_GOARCH}
	export CGO_ENABLED="1"
	export CGO_CFLAGS="${CFLAGS} --sysroot=${STAGING_DIR_TARGET}"
	export CGO_LDFLAGS="${LDFLAGS} --sysroot=${STAGING_DIR_TARGET}"
	export GOFLAGS="${GOFLAGS} -trimpath ${PIEFLAG}"

	oe_runmake GO=${GO} BUILDTAGS="${BUILDTAGS}" binaries
}

do_install() {
        install -d "${D}${BIN_PREFIX}${base_bindir}"
        install -m 755 "${S}/src/import/_output/nerdctl" "${D}${BIN_PREFIX}${base_bindir}"
}

INHIBIT_PACKAGE_STRIP = "1"
INSANE_SKIP:${PN} += "ldflags already-stripped"
