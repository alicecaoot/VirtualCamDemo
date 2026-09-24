/*
 * video_to_iosurface.m — AVAssetReader 逐帧 → IOSurface (BGRA)
 *
 * 对外是 C API；内部用 ObjC 对象持有 AVFoundation 状态，兼容 -fobjc-arc。
 */

#import "video_to_iosurface.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@interface VTISession : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL loop;
@property (nonatomic, assign) int32_t width;
@property (nonatomic, assign) int32_t height;
@property (nonatomic, assign) double fps;
@property (nonatomic, assign) double durationSec;
@property (nonatomic, assign) int64_t frameIndex;
@property (nonatomic, assign) BOOL reachedEOF;
@property (nonatomic, assign) BOOL fatal;

@property (nonatomic, strong) AVAsset *asset;
@property (nonatomic, strong) AVAssetTrack *videoTrack;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderVideoCompositionOutput *output;
@property (nonatomic, strong) AVVideoComposition *videoComposition;
@end

@implementation VTISession
@end

/* 对外仍是不透明指针，实际指向 VTISession * */
struct VTIContext {
	void *session; /* VTISession * */
};

static VTISession *vti_sess(VTIContext *ctx) {
	return ctx ? (__bridge VTISession *)ctx->session : nil;
}

static void vti_log(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fputs("[vti] ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
}

static CGSize vti_display_size_for_track(AVAssetTrack *track) {
	CGSize natural = track.naturalSize;
	CGAffineTransform t = track.preferredTransform;
	CGSize rendered = CGSizeApplyAffineTransform(natural, t);
	return CGSizeMake(fabs(rendered.width), fabs(rendered.height));
}

static NSDictionary *vti_bgra_pixel_buffer_settings(void) {
	return @{
		(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
		(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
	};
}

static BOOL vti_rebuild_reader(VTISession *s) {
	if (!s.asset || !s.videoTrack) {
		return NO;
	}

	NSError *error = nil;

	if (s.reader) {
		if (s.reader.status == AVAssetReaderStatusReading) {
			[s.reader cancelReading];
		}
		s.reader = nil;
		s.output = nil;
	}

	AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:s.asset error:&error];
	if (!reader) {
		vti_log("AVAssetReader init failed: %s",
			error.localizedDescription.UTF8String ?: "?");
		s.fatal = YES;
		return NO;
	}

	/* 用 Mutable 便于校正 renderSize（竖屏 transform 等） */
	AVMutableVideoComposition *composition =
		[AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:s.asset];
	if (!composition) {
		vti_log("videoCompositionWithPropertiesOfAsset failed");
		s.fatal = YES;
		return NO;
	}

	CGSize rs = composition.renderSize;
	if (rs.width < 1 || rs.height < 1) {
		rs = vti_display_size_for_track(s.videoTrack);
		composition.renderSize = rs;
	}

	AVAssetReaderVideoCompositionOutput *output =
		[[AVAssetReaderVideoCompositionOutput alloc]
			initWithVideoTracks:@[ s.videoTrack ]
			      videoSettings:vti_bgra_pixel_buffer_settings()];
	output.videoComposition = composition;
	output.alwaysCopiesSampleData = NO;

	if (![reader canAddOutput:output]) {
		vti_log("canAddOutput == NO");
		s.fatal = YES;
		return NO;
	}
	[reader addOutput:output];

	if (![reader startReading]) {
		vti_log("startReading failed: %s",
			reader.error.localizedDescription.UTF8String ?: "?");
		s.fatal = YES;
		return NO;
	}

	s.reader = reader;
	s.output = output;
	s.videoComposition = composition;
	s.width = (int32_t)lround(composition.renderSize.width);
	s.height = (int32_t)lround(composition.renderSize.height);
	s.reachedEOF = NO;
	return s.width > 0 && s.height > 0;
}

static bool vti_copy_pixel_buffer_to_surface(CVPixelBufferRef pb, IOSurfaceRef surface) {
	if (!pb || !surface) {
		return false;
	}

	const size_t pb_w = CVPixelBufferGetWidth(pb);
	const size_t pb_h = CVPixelBufferGetHeight(pb);
	const size_t sf_w = IOSurfaceGetWidth(surface);
	const size_t sf_h = IOSurfaceGetHeight(surface);
	if (pb_w != sf_w || pb_h != sf_h) {
		vti_log("size mismatch pixelbuffer %zux%zu vs surface %zux%zu",
			pb_w, pb_h, sf_w, sf_h);
		return false;
	}

	if (CVPixelBufferGetPixelFormatType(pb) != kCVPixelFormatType_32BGRA) {
		vti_log("unexpected pixel format %u",
			(unsigned)CVPixelBufferGetPixelFormatType(pb));
		return false;
	}

	if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
		vti_log("CVPixelBufferLockBaseAddress failed");
		return false;
	}

	const void *src = CVPixelBufferGetBaseAddress(pb);
	const size_t src_bpr = CVPixelBufferGetBytesPerRow(pb);
	const bool ok = isb_fill_from_bgra(surface, src, src_bpr);

	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	return ok;
}

static bool vti_copy_pixel_buffer_to_bgra(CVPixelBufferRef pb,
					 void *dst,
					 size_t dst_bpr,
					 int32_t expect_w,
					 int32_t expect_h) {
	if (!pb || !dst) {
		return false;
	}
	const size_t pb_w = CVPixelBufferGetWidth(pb);
	const size_t pb_h = CVPixelBufferGetHeight(pb);
	if ((int32_t)pb_w != expect_w || (int32_t)pb_h != expect_h) {
		vti_log("size mismatch on bgra copy");
		return false;
	}
	if (CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
		return false;
	}

	const uint8_t *src = (const uint8_t *)CVPixelBufferGetBaseAddress(pb);
	const size_t src_bpr = CVPixelBufferGetBytesPerRow(pb);
	const size_t row_bytes = (size_t)expect_w * (size_t)kISBBytesPerPixel;
	uint8_t *d = (uint8_t *)dst;

	bool ok = true;
	if (dst_bpr < row_bytes || src_bpr < row_bytes) {
		ok = false;
	} else {
		for (int32_t y = 0; y < expect_h; y++) {
			memcpy(d + (size_t)y * dst_bpr, src + (size_t)y * src_bpr, row_bytes);
		}
	}

	CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
	return ok;
}

static CVPixelBufferRef vti_next_pixel_buffer(VTISession *s, bool *out_eof) {
	if (out_eof) {
		*out_eof = false;
	}
	if (!s || s.fatal) {
		return NULL;
	}
	if (!s.reader || !s.output) {
		if (!vti_rebuild_reader(s)) {
			return NULL;
		}
	}

	for (;;) {
		if (s.reader.status == AVAssetReaderStatusFailed) {
			vti_log("reader failed: %s",
				s.reader.error.localizedDescription.UTF8String ?: "?");
			s.fatal = YES;
			return NULL;
		}

		CMSampleBufferRef sample = [s.output copyNextSampleBuffer];
		if (sample) {
			CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sample);
			if (!pb) {
				CFRelease(sample);
				continue;
			}
			CVPixelBufferRetain(pb);
			CFRelease(sample);
			return pb;
		}

		if (s.reader.status == AVAssetReaderStatusCompleted ||
		    s.reader.status == AVAssetReaderStatusCancelled) {
			s.reachedEOF = YES;
			if (out_eof) {
				*out_eof = true;
			}
			if (s.loop) {
				if (!vti_rebuild_reader(s)) {
					return NULL;
				}
				continue;
			}
			return NULL;
		}

		if (s.reader.status == AVAssetReaderStatusReading) {
			vti_log("copyNextSampleBuffer returned NULL while reading");
			s.reachedEOF = YES;
			if (out_eof) {
				*out_eof = true;
			}
			if (s.loop && vti_rebuild_reader(s)) {
				continue;
			}
			return NULL;
		}

		s.fatal = YES;
		return NULL;
	}
}

VTIContext *vti_open(const char *path, bool loop) {
	if (!path || !path[0]) {
		return NULL;
	}

	NSURL *url = [NSURL fileURLWithPath:@(path) isDirectory:NO];
	if (!url) {
		return NULL;
	}

	AVURLAsset *asset =
		[[AVURLAsset alloc] initWithURL:url
					options:@{ AVURLAssetPreferPreciseDurationAndTimingKey : @YES }];
	if (!asset) {
		vti_log("AVURLAsset failed for %s", path);
		return NULL;
	}

	dispatch_semaphore_t sema = dispatch_semaphore_create(0);
	__block NSError *load_err = nil;
	[asset loadValuesAsynchronouslyForKeys:@[ @"tracks", @"duration" ]
			     completionHandler:^{
				     dispatch_semaphore_signal(sema);
			     }];
	dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

	if ([asset statusOfValueForKey:@"tracks" error:&load_err] != AVKeyValueStatusLoaded) {
		vti_log("load tracks failed: %s",
			load_err.localizedDescription.UTF8String ?: path);
		return NULL;
	}

	NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
	if (tracks.count < 1) {
		vti_log("no video track: %s", path);
		return NULL;
	}

	VTISession *s = [[VTISession alloc] init];
	s.path = @(path);
	s.loop = loop ? YES : NO;
	s.asset = asset;
	s.videoTrack = tracks.firstObject;

	CGSize disp = vti_display_size_for_track(s.videoTrack);
	s.width = (int32_t)lround(disp.width);
	s.height = (int32_t)lround(disp.height);

	float nominal = s.videoTrack.nominalFrameRate;
	s.fps = nominal > 0.f ? (double)nominal : 0.0;

	CMTime dur = asset.duration;
	if (CMTIME_IS_NUMERIC(dur) && dur.timescale != 0) {
		s.durationSec = (double)dur.value / (double)dur.timescale;
	}

	if (!vti_rebuild_reader(s)) {
		return NULL;
	}

	VTIContext *ctx = (VTIContext *)calloc(1, sizeof(VTIContext));
	if (!ctx) {
		return NULL;
	}
	/* ARC → 非 ObjC 拥有的堆：用 retain 把 session 生命周期绑到 ctx */
	ctx->session = (__bridge_retained void *)s;

	vti_log("opened %s %dx%d fps=%.3f dur=%.3fs loop=%d",
		path, s.width, s.height, s.fps, s.durationSec, (int)loop);
	return ctx;
}

void vti_close(VTIContext *ctx) {
	if (!ctx) {
		return;
	}
	VTISession *s = vti_sess(ctx);
	if (s.reader && s.reader.status == AVAssetReaderStatusReading) {
		[s.reader cancelReading];
	}
	s.reader = nil;
	s.output = nil;
	s.videoComposition = nil;
	s.videoTrack = nil;
	s.asset = nil;

	if (ctx->session) {
		(void)(__bridge_transfer VTISession *)ctx->session;
		ctx->session = NULL;
	}
	free(ctx);
}

bool vti_get_info(VTIContext *ctx, VTIVideoInfo *out_info) {
	VTISession *s = vti_sess(ctx);
	if (!s || !out_info) {
		return false;
	}
	out_info->width = s.width;
	out_info->height = s.height;
	out_info->fps = s.fps;
	out_info->duration_sec = s.durationSec;
	out_info->frame_index = s.frameIndex;
	return true;
}

int32_t vti_width(VTIContext *ctx) {
	VTISession *s = vti_sess(ctx);
	return s ? s.width : 0;
}

int32_t vti_height(VTIContext *ctx) {
	VTISession *s = vti_sess(ctx);
	return s ? s.height : 0;
}

IOSurfaceRef vti_create_surface(VTIContext *ctx, bool global, IOSurfaceID *out_id) {
	VTISession *s = vti_sess(ctx);
	if (!s || s.width <= 0 || s.height <= 0) {
		return NULL;
	}
	IOSurfaceRef surface = isb_create(s.width, s.height, global);
	if (!surface) {
		return NULL;
	}
	if (out_id) {
		*out_id = IOSurfaceGetID(surface);
	}
	return surface;
}

bool vti_copy_next_frame(VTIContext *ctx, IOSurfaceRef surface, bool *out_eof) {
	if (out_eof) {
		*out_eof = false;
	}
	VTISession *s = vti_sess(ctx);
	if (!s || !surface || s.fatal) {
		return false;
	}

	if (IOSurfaceGetWidth(surface) != (size_t)s.width ||
	    IOSurfaceGetHeight(surface) != (size_t)s.height) {
		vti_log("surface size must be %dx%d", s.width, s.height);
		return false;
	}

	bool eof = false;
	CVPixelBufferRef pb = vti_next_pixel_buffer(s, &eof);
	if (!pb) {
		if (out_eof) {
			*out_eof = eof || s.reachedEOF;
		}
		/* loop=false 且正常播完：true + eof；其它失败：false */
		return !s.fatal && eof && !s.loop;
	}

	const bool ok = vti_copy_pixel_buffer_to_surface(pb, surface);
	CVPixelBufferRelease(pb);
	if (!ok) {
		return false;
	}

	s.frameIndex++;
	if (out_eof) {
		*out_eof = false;
	}
	return true;
}

bool vti_copy_next_frame_bgra(VTIContext *ctx,
			      void *dst_bgra,
			      size_t dst_bytes_per_row,
			      bool *out_eof) {
	if (out_eof) {
		*out_eof = false;
	}
	VTISession *s = vti_sess(ctx);
	if (!s || !dst_bgra || s.fatal) {
		return false;
	}

	bool eof = false;
	CVPixelBufferRef pb = vti_next_pixel_buffer(s, &eof);
	if (!pb) {
		if (out_eof) {
			*out_eof = eof || s.reachedEOF;
		}
		return !s.fatal && eof && !s.loop;
	}

	const bool ok =
		vti_copy_pixel_buffer_to_bgra(pb, dst_bgra, dst_bytes_per_row, s.width, s.height);
	CVPixelBufferRelease(pb);
	if (!ok) {
		return false;
	}

	s.frameIndex++;
	return true;
}

bool vti_rewind(VTIContext *ctx) {
	VTISession *s = vti_sess(ctx);
	if (!s || s.fatal) {
		return false;
	}
	s.frameIndex = 0;
	return vti_rebuild_reader(s) ? true : false;
}

void vti_sleep_for_frame_interval(VTIContext *ctx) {
	VTISession *s = vti_sess(ctx);
	double fps = (s && s.fps > 0.0) ? s.fps : 30.0;
	if (fps < 1.0) {
		fps = 1.0;
	}
	const useconds_t us = (useconds_t)(1000000.0 / fps);
	if (us > 0) {
		usleep(us);
	}
}
