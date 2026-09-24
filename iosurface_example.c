/*
 * iosurface_example.c — 创建 / 填充 / 跨进程打开 / 读取 示例
 *
 * 默认不链进 tweak。要在本机逻辑里试用，可在 Makefile 加入本文件，
 * 并在 Tweak.x 里声明：void isb_run_self_test(void); 然后在 %ctor 调用。
 *
 * 真跨进程：进程 A 把 IOSurfaceID 发给 B，B 调 isb_lookup。
 */

#include "iosurface_buffer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void isb_run_self_test(void) {
	const int32_t W = 64;
	const int32_t H = 48;

	/* ---------- 进程 A：创建 + 填像素 ---------- */
	ISBPixelBGRA red = { .b = 0, .g = 0, .r = 255, .a = 255 };
	IOSurfaceID shared_id = 0;
	IOSurfaceRef producer = isb_create_filled(W, H, true /* global */, red, &shared_id);
	if (!producer) {
		fprintf(stderr, "[isb] create failed\n");
		return;
	}

	ISBInfo info;
	isb_get_info(producer, &info);
	fprintf(stderr,
		"[isb] producer id=%u %dx%d bpr=%zu alloc=%zu\n",
		(unsigned)info.surface_id,
		info.width,
		info.height,
		info.bytes_per_row,
		info.alloc_size);

	/* 改一个角上的像素 */
	ISBPixelBGRA blue = { .b = 255, .g = 0, .r = 0, .a = 255 };
	isb_set_pixel(producer, 0, 0, blue);

	/* 从紧凑缓冲整帧写入示例 */
	{
		const size_t tight_bpr = (size_t)W * kISBBytesPerPixel;
		uint8_t *frame = (uint8_t *)calloc((size_t)H, tight_bpr);
		if (frame) {
			for (int32_t y = 0; y < H; y++) {
				for (int32_t x = 0; x < W; x++) {
					ISBPixelBGRA *px =
						(ISBPixelBGRA *)(frame + (size_t)y * tight_bpr +
								 (size_t)x * kISBBytesPerPixel);
					px->b = (uint8_t)(x * 2);
					px->g = (uint8_t)(y * 3);
					px->r = 32;
					px->a = 255;
				}
			}
			isb_fill_from_bgra(producer, frame, tight_bpr);
			free(frame);
		}
	}

	/*
	 * 此处把 shared_id 发给另一进程，例如：
	 *   - xpc_dictionary_set_uint64(msg, "iosurface_id", shared_id);
	 *   - 写到你自己的 socket / 文件
	 * 接收方只拿得到 ID，拿不到本进程的 IOSurfaceRef。
	 */
	fprintf(stderr, "[isb] hand off surface_id=%u to other process\n", (unsigned)shared_id);

	/* ---------- 进程 B：lookup + 读像素（同进程模拟） ---------- */
	IOSurfaceRef consumer = isb_lookup(shared_id);
	if (!consumer) {
		fprintf(stderr, "[isb] lookup failed (need kIOSurfaceIsGlobal)\n");
		CFRelease(producer);
		return;
	}

	ISBPixelBGRA sample = {0};
	if (isb_get_pixel(consumer, 1, 1, &sample)) {
		fprintf(stderr,
			"[isb] consumer pixel(1,1) = BGRA(%u,%u,%u,%u)\n",
			sample.b, sample.g, sample.r, sample.a);
	}

	/* 整帧读出到紧凑缓冲 */
	{
		const size_t tight_bpr = (size_t)W * kISBBytesPerPixel;
		uint8_t *out = (uint8_t *)malloc((size_t)H * tight_bpr);
		if (out && isb_read_to_bgra(consumer, out, tight_bpr)) {
			ISBPixelBGRA *p0 = (ISBPixelBGRA *)out;
			fprintf(stderr,
				"[isb] readback(0,0) = BGRA(%u,%u,%u,%u)\n",
				p0->b, p0->g, p0->r, p0->a);
		}
		free(out);
	}

	/* 手动 lock 后直接指针访问（图像处理热路径） */
	{
		uint32_t seed = 0;
		if (isb_lock(consumer, &seed)) {
			uint8_t *base = (uint8_t *)isb_base_address(consumer);
			size_t bpr = isb_bytes_per_row(consumer);
			/* 例如：把 (10,10) 写成白 */
			ISBPixelBGRA *px =
				(ISBPixelBGRA *)(base + 10 * bpr + 10 * kISBBytesPerPixel);
			px->b = px->g = px->r = px->a = 255;
			isb_unlock(consumer, &seed);
		}
	}

	CFRelease(consumer);
	CFRelease(producer);
	fprintf(stderr, "[isb] self-test done\n");
}
