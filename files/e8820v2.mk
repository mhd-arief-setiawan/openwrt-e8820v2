
define Device/zte_e8820v2
  $(Device/dsa-migration)
  $(Device/uimage-lzma-loader)
  IMAGE_SIZE := 16064k
  DEVICE_VENDOR := ZTE
  DEVICE_MODEL := E8820V2
  # 5GHz-only (mt7612) to save RAM on the 64MB board; mt7603 (2.4GHz) omitted.
  DEVICE_PACKAGES := kmod-mt76x2
endef
TARGET_DEVICES += zte_e8820v2
