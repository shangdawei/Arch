#!/bin/bash
#****************************************************************************
#*   $Id:: LinuxNXPISP 4528 2012-09-11 23:32:22Z nxp41504                      $
#*   Project: Linux NXP ISP example
#*
#*   Description:
#*     This is a bash script tested in Ubuntu 10.04 that scans for NXP
#*     LPC1XXX devices in USB ISP mode and updates their firmware. It
#*     depends on lsusb, udev, udevadmin, and mount.
#*
#*   Modified by Yihui Xiong 2013-12-03:
#*     Check if the sum of new firmware's first 8 word(4 bytes) is zero. If not,
#*     fix it.
#*
#****************************************************************************
#* Software that is described herein is for illustrative purposes only
#* which provides customers with programming information regarding the
#* products. This software is supplied "AS IS" without any warranties.
#* NXP Semiconductors assumes no responsibility or liability for the
#* use of the software, conveys no license or title under any patent,
#* copyright, or mask work right to the product. NXP Semiconductors
#* reserves the right to make changes in the software without
#* notification. NXP Semiconductors also make no representation or
#* warranty that such application will be suitable for the specified
#* use without further testing or modification.
#***************************************************************************/
if [ $# != 1 ]; then
	echo "This program will program new firmware into an NXP LPC1xxx device"
	echo "in USB In-System Programming (ISP) mode. Start it with a path to"
	echo "the new firmware."
	echo ""
	echo "$0 <path to new firmware>"
	exit 1
fi

bin="$1"

if [ ! -f "$bin" ]; then
	echo "Cannot open firmware file $bin"
	exit 2
fi

# check if the sum of new firmware's first 8 word(4 bytes) is zero
od -N 32 -t u4 -v -w32 "$bin" > /tmp/lpc1xxx
read addr u1 u2 u3 u4 u5 u6 u7 u8 < /tmp/lpc1xxx
sum=$(($u1 + $u2 + $u3 + $u4 + $u5 + $u6 + $u7))
cks=$(((~$sum + 1) & 0xFFFFFFFF))
if [ $u8 != $cks ]; then
    echo "fix the checksum of the new firmware"
    # for big endian
    # printf "0: %0.8X" $cks | xxd -r -g0 > /tmp/lpc1xxx
    # for little endian
    printf "0: %.8X" $cks | sed -E 's/0: (..)(..)(..)(..)/0: \4\3\2\1/' | xxd -r -g0 > /tmp/lpc1xxx
    cp "$bin" /tmp/lpc1xxx.bin
    dd bs=4 count=1 seek=7 conv=notrunc if=/tmp/lpc1xxx of=/tmp/lpc1xxx.bin
    xxd -l 128 /tmp/lpc1xxx.bin
    bin="/tmp/lpc1xxx.bin"
fi

echo "Searching for NXP LPC1xxx MCU in USB ISP mode..."

# lsusb -d will return output like this:
# Bus 007 Device 002: ID 04cc:0003 Philips Semiconductors 
lsusb -d "1FC9:" |
#                  Bus  007 Device 002:   ID   04cc:0003 Philips Semiconductors
while IFS=" " read lab1 bus lab2   device lab3 id        mfg
do
	device="${device:0:3}" # remove trailing ':' from device number
	echo "Found USB bus number: $bus device number: $device"

	# make udev path for USB device
	path="/dev/bus/usb/$bus/$device"
	echo "Linux UDEV device path should be: $path"
	echo "Now reading USB device info."

	# read USB model ID for that device using udevadm
	model=$(udevadm info -q property -n $path | grep ID_MODEL=)
	model="${model:9}"
	echo "Device Model ID is $model"
	if [ $model != "LPC1XXX_IFLASH" ]; then
		echo "Model does not match: Not \"LPC1XXX_IFLASH\""
	else
		echo "Correct model ID found."
		echo "Searching for disk devices with matching device path..."

		# convert our udev path into a much longer kernel device filename
		devpath=$(udevadm info -q path -n $path)

		# iterate through all of the disk devices, assuming they start with
		# sd and have one letter in them.
		for disk in /dev/sd[a-z]; do
			echo "Checking disk $disk..."
			# run udevadm again to get the kernel device filename for
			# the disk device we are checking.
			diskdevpath=$(udevadm info -q path -n $disk)
			# test to see if the disk device's kernel file matches the
			# USB device's kernel file
			if [ $devpath = ${diskdevpath:0:${#devpath}} ]; then
				echo "Match found: Disk device is $disk"
				# We found the disk for our USB device. Now test to
				# see if we can find it in the mount command output.
				# /dev/sdc on /media/CRP DISABLD type vfat (rw,nosuid,nodev,uhelper=udisks,uid=1000,gid=1000,shortname=mixed,dmask=0077,utf8=1,flush)
				volpath=$(mount | grep "^$disk " | cut -d' ' -f3- | cut -d'(' -f1)
				# volpath should be: /media/CRP DISABLD type vfat
				if [ "$volpath" = "" ]; then
					echo "Update firmware without mounting $disk."
					sudo dd bs=512 seek=4 conv=notrunc if="$bin" of="$disk" 
                    echo "Firmware update complete!"
				else
					# Get the volume path from the mount command output
					# make volpath look like: /media/CRP DISABLD
					volpath="${volpath:0:${#volpath} - 11}"

					# create file path for firmware.bin on ISP device
					volpath="${volpath}/firmware.bin"
					echo LPC ISP disk path: $volpath

					# get the firmware sizes as a sanity check
					fwsize=$(stat -c %s "$volpath")
					newfwsize=$(stat -c %s "$bin")
					echo LPC ISP flash size / new firmware size: $fwsize $newfwsize

                    # Get volume label from mount command. This is used to check
                    # for code protect. This is a non-standard extension to mount
                    # and will cause a compatibility problem with some variants
                    # of linux/unix (Mac OS-X for example).
                    vollabel=$(mount -l | grep "^$disk " | cut -d'[' -f2- | cut -d']' -f1)
                    # desired result: CRP DISABLD
                    echo "Volume label $vollabel"
                    if [ "$vollabel" != "CRP DISABLD" ]; then
                        echo "Cannot flash device- it is code protected!"
                        # Left as an exercise to the reader- at this point the
                        # old firmware.bin file could be deleted and the user
                        # could be asked to remove and reinsert the device to
                        # reset code protect so it could be updated.
                    else
                        # dd is used to update firmware.bin in place. The cp
                        # command will truncate firmware.bin which will cause
                        # the linux vfat filesystem to reallocate the blocks
                        # in a different order, scrambling the firmware update
                        # flash writes.
                        dd bs=512 conv=nocreat,notrunc if="$bin" of="$volpath"
                        echo "Firmware update complete!"

                        # unmount device when done to ensure that all of the
                        # data is written to the NXP LPC ISP device
                        umount "$disk"
                        echo "Device unmounted."
                    fi
				fi
			fi
		done
	fi
done

# remove tmp files
rm -f /tmp/lpc1xxx /tmp/lpc1xxx.bin

