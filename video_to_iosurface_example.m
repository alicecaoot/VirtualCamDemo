/*
 * video_to_iosurface_example.m — 视频 → IOSurface 推流示例
 *
 * Makefile 取消注释本文件后，在 Tweak.x：
 *   extern void vti_run_file_to_surface_demo(const char *path);
 *   %ctor { vti_run_file_to_surface_demo("/var/mobile/Documents/demo.mp4"); }
 *
 * 把 mp4 放到设备可读路径；沙盒 App 用自己的 Documents。
 */

#import "video_to_iosurface.h"

#include <stdio.h>

void vti_run_file_to_surface_demo(const char *path) {
	if (!path) {
		path = "/var/mobile/Documents/demo.mp4";
	}

	VTIContext *v = vti_open(path, true /* loop */);
	if (!v) {
		fprintf(stderr, "[vti-demo] open failed: %s\n", path);
		return;
	}

	VTIVideoInfo info;
	vti_get_info(v, &info);
	fprintf(stderr,
		"[vti-demo] %dx%d fps=%.2f duration=%.2fs\n",
		info.width, info.height, info.fps, info.duration_sec);

	IOSurfaceID sid = 0;
	IOSurfaceRef surface = vti_create_surface(v, true, &sid);
	if (!surface) {
		fprintf(stderr, "[vti-demo] create surface failed\n");
		vti_close(v);
		return;
	}
	fprintf(stderr, "[vti-demo] surface_id=%u (hand off to other process)\n", (unsigned)sid);

	/* 演示推 N 帧；正式用可丢到后台队列循环 */
	const int max_frames = 300;
	for (int i = 0; i < max_frames; i++) {
		bool eof = false;
		if (!vti_copy_next_frame(v, surface, &eof)) {
			fprintf(stderr, "[vti-demo] copy failed at i=%d\n", i);
			break;
		}
		if (eof) {
			fprintf(stderr, "[vti-demo] eof signal at i=%d\n", i);
		}
		if ((i % 30) == 0) {
			vti_get_info(v, &info);
			ISBPixelBGRA px = {0};
			isb_get_pixel(surface, info.width / 2, info.height / 2, &px);
			fprintf(stderr,
				"[vti-demo] frame=%lld center BGRA(%u,%u,%u,%u)\n",
				(long long)info.frame_index,
				px.b, px.g, px.r, px.a);
		}
		vti_sleep_for_frame_interval(v);
	}

	CFRelease(surface);
	vti_close(v);
	fprintf(stderr, "[vti-demo] done\n");
}
