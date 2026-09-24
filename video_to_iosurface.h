/*
 * video_to_iosurface.h — 从视频文件逐帧解码，写入 IOSurface
 *
 * 依赖：AVFoundation / CoreMedia / CoreVideo + iosurface_buffer
 *
 * 典型用法：
 *   VTIContext *v = vti_open("/var/mobile/Media/my.mp4", true);
 *   IOSurfaceID id = 0;
 *   IOSurfaceRef s = vti_create_surface(v, true, &id);  // 把 id 交给其它进程
 *   for (;;) {
 *       bool eof = false;
 *       if (!vti_copy_next_frame(v, s, &eof)) break;
 *       if (eof) continue; // loop=true 时已自动 rewind
 *       // 消费者侧 lookup(id) 即可看到最新帧
 *   }
 *   CFRelease(s);
 *   vti_close(v);
 */

#ifndef VIDEO_TO_IOSURFACE_H
#define VIDEO_TO_IOSURFACE_H

#include "iosurface_buffer.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VTIContext VTIContext;

typedef struct VTIVideoInfo {
	int32_t width;          /* 显示宽（已考虑旋转） */
	int32_t height;         /* 显示高 */
	double fps;             /* 标称帧率，未知时为 0 */
	double duration_sec;    /* 时长秒，未知时为 0 */
	int64_t frame_index;    /* 已成功写出的帧计数（从 0 起） */
} VTIVideoInfo;

/*
 * 打开本地视频文件（H.264/HEVC/等容器均可，系统能解的格式）。
 * path: UTF-8 路径，如 /var/mobile/Documents/clip.mp4
 * loop: 读到结尾后是否自动从头循环
 * 失败返回 NULL。
 */
VTIContext *vti_open(const char *path, bool loop);

/* 释放解码器与内部 reader；ctx 可传 NULL */
void vti_close(VTIContext *ctx);

/* 只读信息；失败返回 false */
bool vti_get_info(VTIContext *ctx, VTIVideoInfo *out_info);

int32_t vti_width(VTIContext *ctx);
int32_t vti_height(VTIContext *ctx);

/*
 * 按视频显示尺寸创建 IOSurface（BGRA，可 global 跨进程）。
 * out_id 可 NULL。失败返回 NULL。
 */
IOSurfaceRef vti_create_surface(VTIContext *ctx, bool global, IOSurfaceID *out_id);

/*
 * 解码下一帧并拷入 surface（BGRA）。
 *
 * surface 宽高必须与 vti_width/height 一致，否则返回 false。
 * out_eof 可 NULL；当 loop=false 且已无末帧后再调，*out_eof=true 且返回 true
 * （不再写入）。loop=true 时会静默 rewind，*out_eof 仅在内部重启时为 true 一帧可选信号。
 *
 * 成功写出一帧返回 true；致命错误返回 false。
 */
bool vti_copy_next_frame(VTIContext *ctx, IOSurfaceRef surface, bool *out_eof);

/*
 * 解码下一帧到「调用方提供的紧凑 BGRA 缓冲」（stride = width*4）。
 * 缓冲大小需 >= width * height * 4。便于先处理再自己写入 surface。
 */
bool vti_copy_next_frame_bgra(VTIContext *ctx,
			      void *dst_bgra,
			      size_t dst_bytes_per_row,
			      bool *out_eof);

/* 重新从头播放（重建 AVAssetReader） */
bool vti_rewind(VTIContext *ctx);

/*
 * 可选：按视频标称 fps 休眠，接近实时推流。
 * 在 vti_copy_next_frame 成功后调用；fps 未知时按 30。
 */
void vti_sleep_for_frame_interval(VTIContext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* VIDEO_TO_IOSURFACE_H */
