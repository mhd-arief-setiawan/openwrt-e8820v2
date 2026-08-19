
define Device/zte_e8820v2
  $(Device/dsa-migration)
  $(Device/uimage-lzma-loader)
  IMAGE_SIZE := 16064k
  DEVICE_VENDOR := ZTE
  DEVICE_MODEL := E8820V2
  DEVICE_PACKAGES := kmod-mt7603 kmod-mt76x2 kmod-usb2 \
	  kmod-usb-ledtrig-usbport
endef
TARGET_DEVICES += zte_e8820v2
