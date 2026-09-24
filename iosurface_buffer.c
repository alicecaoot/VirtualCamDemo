/*
 * iosurface_buffer.c — IOSurface 创建 / 填像素 / 读取
 */

#include "iosurface_buffer.h"

#include <IOSurface/IOSurface.h>
#include <string.h>

/* 部分 SDK 头文件宏名略有差异，统一兜底 */
#ifndef kIOSurfaceBytesPerElement
#define kIOSurfaceBytesPerElement CFSTR("BytesPerElement")
#endif
#ifndef kIOSurfaceElementWidth
#define kIOSurfaceElementWidth CFSTR("ElementWidth")
#endif
#ifndef kIOSurfaceElementHeight
#define kIOSurfaceElementHeight CFSTR("ElementHeight")
#endif

/* 'BGRA' 四字符码：iOS 上 IOSurface / CVPixelBuffer 常用 */
#ifndef kISBPixelFormatBGRA
#define kISBPixelFormatBGRA 0x42475241u /* 'BGRA' */
#endif

static CFNumberRef isb_cfnum_i32(int32_t v) {
	return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
}

static CFNumberRef isb_cfnum_i64(int64_t v) {
	return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &v);
}

IOSurfaceRef isb_create(int32_t width, int32_t height, bool global) {
	if (width <= 0 || height <= 0) {
		return NULL;
	}

	const int32_t bytes_per_element = kISBBytesPerPixel;
	/* 行字节数按 16 字节对齐，减少未定义 stride 行为 */
	const int32_t raw_bpr = width * bytes_per_element;
	const int32_t bytes_per_row = (raw_bpr + 15) & ~15;
	const int64_t alloc_size = (int64_t)bytes_per_row * (int64_t)height;
	const int32_t pixel_format = (int32_t)kISBPixelFormatBGRA;
	const int32_t element_w = 1;
	const int32_t element_h = 1;
	const uint32_t cache_mode = (uint32_t)kIOMapDefaultCache;

	CFMutableDictionaryRef props = CFDictionaryCreateMutable(
		kCFAllocatorDefault,
		0,
		&kCFTypeDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks);
	if (!props) {
		return NULL;
	}

	CFNumberRef n;

	n = isb_cfnum_i32(width);
	CFDictionarySetValue(props, kIOSurfaceWidth, n);
	CFRelease(n);

	n = isb_cfnum_i32(height);
	CFDictionarySetValue(props, kIOSurfaceHeight, n);
	CFRelease(n);

	n = isb_cfnum_i32(bytes_per_row);
	CFDictionarySetValue(props, kIOSurfaceBytesPerRow, n);
	CFRelease(n);

	n = isb_cfnum_i32(bytes_per_element);
	CFDictionarySetValue(props, kIOSurfaceBytesPerElement, n);
	CFRelease(n);

	n = isb_cfnum_i32(element_w);
	CFDictionarySetValue(props, kIOSurfaceElementWidth, n);
	CFRelease(n);

	n = isb_cfnum_i32(element_h);
	CFDictionarySetValue(props, kIOSurfaceElementHeight, n);
	CFRelease(n);

	n = isb_cfnum_i32(pixel_format);
	CFDictionarySetValue(props, kIOSurfacePixelFormat, n);
	CFRelease(n);

	n = isb_cfnum_i64(alloc_size);
	CFDictionarySetValue(props, kIOSurfaceAllocSize, n);
	CFRelease(n);

	n = isb_cfnum_i32((int32_t)cache_mode);
	CFDictionarySetValue(props, kIOSurfaceCacheMode, n);
	CFRelease(n);

	if (global) {
		/* 全局 surface，其它进程 IOSurfaceLookup(ID) 可打开 */
		CFDictionarySetValue(props, kIOSurfaceIsGlobal, kCFBooleanTrue);
	}

	IOSurfaceRef surface = IOSurfaceCreate(props);
	CFRelease(props);
	return surface;
}

IOSurfaceRef isb_lookup(IOSurfaceID surface_id) {
	if (surface_id == 0) {
		return NULL;
	}
	return IOSurfaceLookup(surface_id);
}

bool isb_get_info(IOSurfaceRef surface, ISBInfo *out_info) {
	if (!surface || !out_info) {
		return false;
	}
	memset(out_info, 0, sizeof(*out_info));
	out_info->width = (int32_t)IOSurfaceGetWidth(surface);
	out_info->height = (int32_t)IOSurfaceGetHeight(surface);
	out_info->bytes_per_row = IOSurfaceGetBytesPerRow(surface);
	out_info->alloc_size = IOSurfaceGetAllocSize(surface);
	out_info->surface_id = IOSurfaceGetID(surface);
	return out_info->width > 0 && out_info->height > 0;
}

bool isb_lock(IOSurfaceRef surface, uint32_t *seed) {
	if (!surface) {
		return false;
	}
	/* kIOSurfaceLockReadOnly 只读；写像素用 0 */
	kern_return_t kr = IOSurfaceLock(surface, 0, seed);
	return kr == KERN_SUCCESS;
}

bool isb_unlock(IOSurfaceRef surface, uint32_t *seed) {
	if (!surface) {
		return false;
	}
	kern_return_t kr = IOSurfaceUnlock(surface, 0, seed);
	return kr == KERN_SUCCESS;
}

void *isb_base_address(IOSurfaceRef surface) {
	if (!surface) {
		return NULL;
	}
	return IOSurfaceGetBaseAddress(surface);
}

size_t isb_bytes_per_row(IOSurfaceRef surface) {
	if (!surface) {
		return 0;
	}
	return IOSurfaceGetBytesPerRow(surface);
}

static bool isb_copy_rows(void *dst_base,
			  size_t dst_bpr,
			  const void *src_base,
			  size_t src_bpr,
			  int32_t width,
			  int32_t height) {
	if (!dst_base || !src_base || width <= 0 || height <= 0) {
		return false;
	}
	const size_t row_bytes = (size_t)width * (size_t)kISBBytesPerPixel;
	if (dst_bpr < row_bytes || src_bpr < row_bytes) {
		return false;
	}

	uint8_t *d = (uint8_t *)dst_base;
	const uint8_t *s = (const uint8_t *)src_base;
	for (int32_t y = 0; y < height; y++) {
		memcpy(d + (size_t)y * dst_bpr, s + (size_t)y * src_bpr, row_bytes);
	}
	return true;
}

bool isb_fill_solid(IOSurfaceRef surface, ISBPixelBGRA color) {
	if (!surface) {
		return false;
	}

	uint32_t seed = 0;
	if (!isb_lock(surface, &seed)) {
		return false;
	}

	const int32_t w = (int32_t)IOSurfaceGetWidth(surface);
	const int32_t h = (int32_t)IOSurfaceGetHeight(surface);
	const size_t bpr = IOSurfaceGetBytesPerRow(surface);
	uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface);
	if (!base || w <= 0 || h <= 0) {
		isb_unlock(surface, &seed);
		return false;
	}

	/* 先填第一行，其余行 memcpy，避免逐像素写 */
	uint8_t *row0 = base;
	for (int32_t x = 0; x < w; x++) {
		ISBPixelBGRA *px = (ISBPixelBGRA *)(row0 + (size_t)x * kISBBytesPerPixel);
		*px = color;
	}
	for (int32_t y = 1; y < h; y++) {
		memcpy(base + (size_t)y * bpr, row0, (size_t)w * kISBBytesPerPixel);
	}

	return isb_unlock(surface, &seed);
}

bool isb_fill_from_bgra(IOSurfaceRef surface,
			const void *src,
			size_t src_bytes_per_row) {
	if (!surface || !src) {
		return false;
	}

	uint32_t seed = 0;
	if (!isb_lock(surface, &seed)) {
		return false;
	}

	const int32_t w = (int32_t)IOSurfaceGetWidth(surface);
	const int32_t h = (int32_t)IOSurfaceGetHeight(surface);
	const size_t dst_bpr = IOSurfaceGetBytesPerRow(surface);
	void *dst = IOSurfaceGetBaseAddress(surface);

	const bool ok = isb_copy_rows(dst, dst_bpr, src, src_bytes_per_row, w, h);
	const bool unlocked = isb_unlock(surface, &seed);
	return ok && unlocked;
}

bool isb_read_to_bgra(IOSurfaceRef surface,
		      void *dst,
		      size_t dst_bytes_per_row) {
	if (!surface || !dst) {
		return false;
	}

	uint32_t seed = 0;
	/* 只读锁即可 */
	kern_return_t kr = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, &seed);
	if (kr != KERN_SUCCESS) {
		return false;
	}

	const int32_t w = (int32_t)IOSurfaceGetWidth(surface);
	const int32_t h = (int32_t)IOSurfaceGetHeight(surface);
	const size_t src_bpr = IOSurfaceGetBytesPerRow(surface);
	const void *src = IOSurfaceGetBaseAddress(surface);

	const bool ok = isb_copy_rows(dst, dst_bytes_per_row, src, src_bpr, w, h);

	kr = IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, &seed);
	return ok && (kr == KERN_SUCCESS);
}

bool isb_set_pixel(IOSurfaceRef surface, int32_t x, int32_t y, ISBPixelBGRA color) {
	if (!surface) {
		return false;
	}

	uint32_t seed = 0;
	if (!isb_lock(surface, &seed)) {
		return false;
	}

	const int32_t w = (int32_t)IOSurfaceGetWidth(surface);
	const int32_t h = (int32_t)IOSurfaceGetHeight(surface);
	if (x < 0 || y < 0 || x >= w || y >= h) {
		isb_unlock(surface, &seed);
		return false;
	}

	uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface);
	const size_t bpr = IOSurfaceGetBytesPerRow(surface);
	ISBPixelBGRA *px =
		(ISBPixelBGRA *)(base + (size_t)y * bpr + (size_t)x * kISBBytesPerPixel);
	*px = color;

	return isb_unlock(surface, &seed);
}

bool isb_get_pixel(IOSurfaceRef surface, int32_t x, int32_t y, ISBPixelBGRA *out_color) {
	if (!surface || !out_color) {
		return false;
	}

	uint32_t seed = 0;
	kern_return_t kr = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, &seed);
	if (kr != KERN_SUCCESS) {
		return false;
	}

	const int32_t w = (int32_t)IOSurfaceGetWidth(surface);
	const int32_t h = (int32_t)IOSurfaceGetHeight(surface);
	if (x < 0 || y < 0 || x >= w || y >= h) {
		IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, &seed);
		return false;
	}

	const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(surface);
	const size_t bpr = IOSurfaceGetBytesPerRow(surface);
	const ISBPixelBGRA *px =
		(const ISBPixelBGRA *)(base + (size_t)y * bpr + (size_t)x * kISBBytesPerPixel);
	*out_color = *px;

	kr = IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, &seed);
	return kr == KERN_SUCCESS;
}

IOSurfaceRef isb_create_filled(int32_t width,
			       int32_t height,
			       bool global,
			       ISBPixelBGRA color,
			       IOSurfaceID *out_id) {
	IOSurfaceRef surface = isb_create(width, height, global);
	if (!surface) {
		return NULL;
	}
	if (!isb_fill_solid(surface, color)) {
		CFRelease(surface);
		return NULL;
	}
	if (out_id) {
		*out_id = IOSurfaceGetID(surface);
	}
	return surface;
}
