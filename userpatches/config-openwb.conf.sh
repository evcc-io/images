source config-rpi.conf.sh

export EXTRA_IMAGE_SUFFIXES+=("-openwb")

function pre_umount_final_image__900_append_to_raspi_config() {
	cat <<- EOD >> "${MOUNT}"/boot/firmware/config.txt
		[all]
		gpio=4,5,7,11,17,22,23,24,25,26,27=op,dl
		gpio=6,8,9,10,12,13,16,21=ip,pu
	EOD
}
