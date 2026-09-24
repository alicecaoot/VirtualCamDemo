/*
 * iosurface_buffer.h — 进程间共享图像缓冲（IOSurface）
 *
 * 典型用法：
 *   1) 进程 A：create → lock → fill → unlock → 把 surface_id 传给 B
 *   2) 进程 B：lookup(surface_id) → lock → read → unlock → release
 *
 * 传 ID 可用：XPC / CFNotification + 共享内存 / 文件 / 你自己的 IPC。
 * IOSurface 本身靠 kernel 按 global ID 映射同一块物理页。
 */

#ifndef IOSURFACE_BUFFER_H
#define IOSURFACE_BUFFER_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* BGRA8888，每像素 4 字节，与 UIKit / CALayer 常见格式一致 */
enum {
	kISBBytesPerPixel = 4
};

typedef struct ISBPixelBGRA {
	uint8_t b;
	uint8_t g;
	uint8_t r;
	uint8_t a;
} ISBPixelBGRA;

typedef struct ISBInfo {
	int32_t width;
	int32_t height;
	size_t bytes_per_row; /* 可能 > width * 4，有对齐 padding */
	size_t alloc_size;
	IOSurfaceID surface_id;
} ISBInfo;

/*
 * 创建可跨进程共享的 IOSurface。
 * global=true 时分配全局 ID，其它进程可用 IOSurfaceLookup 打开。
 * 失败返回 NULL。调用方用 CFRelease 释放。
 */
IOSurfaceRef isb_create(int32_t width, int32_t height, bool global);

/* 用已有全局 ID 在本进程打开（不增加创建方的所有权语义外的额外 retain 规则：返回 +1，需 CFRelease） */
IOSurfaceRef isb_lookup(IOSurfaceID surface_id);

/* 读元数据；surface 为 NULL 时返回 false */
bool isb_get_info(IOSurfaceRef surface, ISBInfo *out_info);

/*
 * 锁定 CPU 读写。seed 传 0 即可（或传入你保存的 seed）。
 * 成功返回 true，此时可用 isb_base_address / isb_bytes_per_row 访问像素。
 */
bool isb_lock(IOSurfaceRef surface, uint32_t *seed /* nullable */);
bool isb_unlock(IOSurfaceRef surface, uint32_t *seed /* nullable */);

void *isb_base_address(IOSurfaceRef surface);
size_t isb_bytes_per_row(IOSurfaceRef surface);

/*
 * 填充整幅为纯色 BGRA。内部 lock/unlock。
 * 注意：按 bytes_per_row 逐行写，跳过行尾 padding。
 */
bool isb_fill_solid(IOSurfaceRef surface, ISBPixelBGRA color);

/*
 * 从紧凑 BGRA 源缓冲拷入 surface（src_bpr = width*4 的紧凑布局，或自定义 stride）。
 * src 大小至少 height * src_bytes_per_row。
 */
bool isb_fill_from_bgra(IOSurfaceRef surface,
			const void *src,
			size_t src_bytes_per_row);

/*
 * 把 surface 像素读到紧凑 BGRA 缓冲（dst_bpr 一般为 width*4）。
 * dst 由调用方分配，大小 >= height * dst_bytes_per_row。
 */
bool isb_read_to_bgra(IOSurfaceRef surface,
		      void *dst,
		      size_t dst_bytes_per_row);

/* 读/写单个像素（会 lock 整张 surface；热路径请自行 lock 后用指针） */
bool isb_set_pixel(IOSurfaceRef surface, int32_t x, int32_t y, ISBPixelBGRA color);
bool isb_get_pixel(IOSurfaceRef surface, int32_t x, int32_t y, ISBPixelBGRA *out_color);

/* 便捷：创建 + 填充纯色，out_id 可为空 */
IOSurfaceRef isb_create_filled(int32_t width,
			       int32_t height,
			       bool global,
			       ISBPixelBGRA color,
			       IOSurfaceID *out_id /* nullable */);

#ifdef __cplusplus
}
#endif

#endif /* IOSURFACE_BUFFER_H */
