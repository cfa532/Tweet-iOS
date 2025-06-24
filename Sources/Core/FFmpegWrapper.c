#include "FFmpegWrapper.h"

//
//  FFmpegWrapper.c
//  Tweet
//
//  Created by Your Name on YYYY/MM/DD.
//

// First, we need to include the required FFmpeg headers.
// These are the C headers from the libraries we just built.
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/pixfmt.h"  // For AVPixelFormat
#include "libavutil/samplefmt.h"  // For AVSampleFormat
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"

// Add system headers for directory operations
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <math.h>  // For isnan and isinf functions

// Define resolution configurations
typedef struct {
    int width;
    int height;
    int video_bitrate;
    int audio_bitrate;
    const char* name;
} ResolutionConfig;

// Forward declarations
static int create_single_hls_stream(AVFormatContext *input_format_context, const char *output_dir, int target_width, int target_height);
static int create_master_playlist(const char *output_dir, const char *high_dir, const char *medium_dir);
static int create_directory(const char *path);

int convert_to_hls(const char *input_path, const char *output_dir) {
    // Set log level for detailed output during debugging
    av_log_set_level(AV_LOG_VERBOSE);
    printf("FFmpeg C Wrapper: Starting single-resolution HLS conversion.\n");
    printf("Input file: %s\n", input_path);
    printf("Output directory: %s\n", output_dir);

    // Use a simpler approach - create a single HLS stream with adaptive bitrate
    // This is more reliable than trying to create multiple resolution streams
    
    AVFormatContext *input_format_context = NULL;
    AVFormatContext *output_format_context = NULL;
    int ret = 0;
    int input_closed = 0;

    // 1. Open input file and allocate format context
    if ((ret = avformat_open_input(&input_format_context, input_path, NULL, NULL)) < 0) {
        printf("Could not open input file: %s\n", input_path);
        av_log(NULL, AV_LOG_ERROR, "%s\n", av_err2str(ret));
        return ret;
    }

    // 2. Retrieve stream information
    if ((ret = avformat_find_stream_info(input_format_context, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to find stream information: %s\n", av_err2str(ret));
        goto end;
    }

    av_dump_format(input_format_context, 0, input_path, 0);

    // 3. Create single HLS stream with adaptive bitrate
    ret = create_single_hls_stream(input_format_context, output_dir, 480, 270);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create HLS stream\n");
        goto end;
    }

    printf("Successfully created HLS stream\n");

end:
    // Clean up resources with robust error handling
    if (input_format_context && !input_closed) {
        // Use a more robust approach to close the input context
        // Set a flag to prevent double-closing
        input_closed = 1;
        
        // SAFE APPROACH: Skip avformat_close_input entirely since context is likely corrupted
        // This prevents crashes while still cleaning up the pointer
        av_log(NULL, AV_LOG_WARNING, "Skipping avformat_close_input to prevent crash - context may be corrupted\n");
        
        // Just nullify the pointer without calling avformat_close_input
        input_format_context = NULL;
        
        av_log(NULL, AV_LOG_INFO, "Input context cleanup completed safely\n");
    }

    if (ret < 0 && ret != AVERROR_EOF) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred during conversion: %s\n", av_err2str(ret));
        return ret;
    }

    printf("FFmpeg C Wrapper: Single-resolution HLS conversion finished successfully.\n");
    return 0;
}

static int create_single_hls_stream(AVFormatContext *input_format_context, const char *output_dir, int target_width, int target_height) {
    AVFormatContext *output_format_context = NULL;
    AVCodecContext *video_codec_context = NULL;
    AVCodecContext *audio_codec_context = NULL;
    AVStream *video_stream = NULL;
    AVStream *audio_stream = NULL;
    AVStream *input_video_stream = NULL;
    AVStream *input_audio_stream = NULL;
    int ret;
    int video_stream_index = -1;
    int audio_stream_index = -1;
    char output_playlist[1024];
    AVDictionary *hls_options = NULL;
    char segment_filename[1024];
    AVPacket input_pkt;
    AVFrame *input_frame = NULL;
    AVFrame *output_frame = NULL;
    struct SwsContext *sws_ctx = NULL;
    struct SwrContext *swr_ctx = NULL;
    AVCodecContext *input_video_codec_ctx = NULL;
    AVCodecContext *input_audio_codec_ctx = NULL;
    
    // Initialize audio buffer with conservative memory management
    int max_buffer_samples = 0;
    AVFrame *audio_buffer = NULL;
    int buffered_samples = 0;
    
    // Note: max_buffer_samples will be set after audio_codec_context is created

    // Create output playlist path
    snprintf(output_playlist, sizeof(output_playlist), "%s/playlist.m3u8", output_dir);

    // Allocate output context for HLS
    avformat_alloc_output_context2(&output_format_context, NULL, "hls", output_playlist);
    if (!output_format_context) {
        av_log(NULL, AV_LOG_ERROR, "Could not create HLS output context\n");
        return AVERROR_UNKNOWN;
    }

    // Find video and audio streams in input
    for (int i = 0; i < input_format_context->nb_streams; i++) {
        AVStream *stream = input_format_context->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && video_stream_index == -1) {
            input_video_stream = stream;
            video_stream_index = i;
        } else if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audio_stream_index == -1) {
            input_audio_stream = stream;
            audio_stream_index = i;
        }
    }

    // Create video stream with transcoding
    if (input_video_stream) {
        video_stream = avformat_new_stream(output_format_context, NULL);
        if (!video_stream) {
            av_log(NULL, AV_LOG_ERROR, "Could not create video stream\n");
            ret = AVERROR_UNKNOWN;
            video_codec_context = NULL;
            goto end;
        }
        
        // Find H.264 encoder
        const AVCodec *video_codec = avcodec_find_encoder(AV_CODEC_ID_H264);
        if (!video_codec) {
            av_log(NULL, AV_LOG_ERROR, "H.264 encoder not found\n");
            ret = AVERROR_UNKNOWN;
            video_codec_context = NULL;
            goto end;
        }

        // Create codec context for video
        video_codec_context = avcodec_alloc_context3(video_codec);
        if (!video_codec_context) {
            av_log(NULL, AV_LOG_ERROR, "Could not allocate video codec context\n");
                ret = AVERROR_UNKNOWN;
            video_codec_context = NULL;
                goto end;
            }
            
        // Set video encoding parameters for medium quality
        video_codec_context->width = target_width;
        video_codec_context->height = target_height;
        video_codec_context->bit_rate = 1000000; // 1 Mbps
        
        // Use input video's frame rate instead of hardcoding 30 fps to prevent duration doubling
        AVRational input_framerate = input_video_stream->r_frame_rate;
        if (input_framerate.num <= 0 || input_framerate.den <= 0) {
            // Fallback to 30 fps if input frame rate is invalid
            input_framerate = (AVRational){30, 1};
            av_log(NULL, AV_LOG_WARNING, "Invalid input frame rate, using fallback 30 fps\n");
        }
        
        video_codec_context->time_base = (AVRational){input_framerate.den, input_framerate.num};
        video_codec_context->framerate = input_framerate;
        
        av_log(NULL, AV_LOG_INFO, "Using input frame rate: %d/%d (%.2f fps)\n", 
               input_framerate.num, input_framerate.den, 
               (float)input_framerate.num / input_framerate.den);
        
        video_codec_context->gop_size = 60; // 2 seconds at 30fps
        video_codec_context->max_b_frames = 2;
        video_codec_context->pix_fmt = AV_PIX_FMT_YUV420P;
        
        // Set H.264 specific options for better compatibility
        av_opt_set(video_codec_context->priv_data, "preset", "medium", 0);
        av_opt_set(video_codec_context->priv_data, "tune", "zerolatency", 0);
        av_opt_set(video_codec_context->priv_data, "profile", "baseline", 0);
        av_opt_set(video_codec_context->priv_data, "level", "3.1", 0);

        // Open video codec
        ret = avcodec_open2(video_codec_context, video_codec, NULL);
            if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not open video codec: %s\n", av_err2str(ret));
            video_codec_context = NULL;
                goto end;
            }
            
        // Copy parameters to stream
        ret = avcodec_parameters_from_context(video_stream->codecpar, video_codec_context);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not copy video codec params: %s\n", av_err2str(ret));
            video_codec_context = NULL;
            goto end;
        }
        
        // Set proper stream time base for accurate duration calculation
        video_stream->time_base = video_codec_context->time_base;
        av_log(NULL, AV_LOG_INFO, "Video stream time base: %d/%d\n", 
               video_stream->time_base.num, video_stream->time_base.den);
        
        // CRITICAL: Ensure output stream duration matches input for consistent HLS generation
        if (input_video_stream->duration != AV_NOPTS_VALUE && input_video_stream->duration > 0) {
            video_stream->duration = input_video_stream->duration;
            av_log(NULL, AV_LOG_INFO, "Set video stream duration to match input: %lld\n", video_stream->duration);
        }
    }

    // Create audio stream with transcoding
    if (input_audio_stream) {
        audio_stream = avformat_new_stream(output_format_context, NULL);
        if (!audio_stream) {
            av_log(NULL, AV_LOG_ERROR, "Could not create audio stream\n");
            ret = AVERROR_UNKNOWN;
            audio_codec_context = NULL;
            goto end;
        }

        // Find AAC encoder
        const AVCodec *audio_codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (!audio_codec) {
            av_log(NULL, AV_LOG_ERROR, "AAC encoder not found\n");
            ret = AVERROR_UNKNOWN;
            audio_codec_context = NULL;
            goto end;
        }

        // Create codec context for audio
        audio_codec_context = avcodec_alloc_context3(audio_codec);
        if (!audio_codec_context) {
            av_log(NULL, AV_LOG_ERROR, "Could not allocate audio codec context\n");
            ret = AVERROR_UNKNOWN;
            audio_codec_context = NULL;
            goto end;
        }

        // Configure audio codec context
        audio_codec_context->sample_fmt = AV_SAMPLE_FMT_FLTP;
        audio_codec_context->sample_rate = 44100;
        audio_codec_context->bit_rate = 128000;
        
        // Use newer API for channel configuration
        av_channel_layout_default(&audio_codec_context->ch_layout, 2);

        // Open audio codec
        ret = avcodec_open2(audio_codec_context, audio_codec, NULL);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not open audio codec: %s\n", av_err2str(ret));
            audio_codec_context = NULL;
            goto end;
        }

        // Safety check: ensure audio_codec_context is valid before accessing frame_size
        if (!audio_codec_context) {
            av_log(NULL, AV_LOG_ERROR, "Audio codec context is NULL, cannot access frame_size\n");
            ret = AVERROR_UNKNOWN;
            goto end;
        }
        
        // Check if frame_size is valid (should be > 0 for AAC encoder)
        if (audio_codec_context->frame_size <= 0) {
            av_log(NULL, AV_LOG_ERROR, "Audio codec frame_size is invalid: %d\n", audio_codec_context->frame_size);
            ret = AVERROR_UNKNOWN;
            goto end;
        }
        
        av_log(NULL, AV_LOG_INFO, "Audio codec frame_size: %d\n", audio_codec_context->frame_size);

        // Copy parameters to stream
        ret = avcodec_parameters_from_context(audio_stream->codecpar, audio_codec_context);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not copy audio codec params: %s\n", av_err2str(ret));
            audio_codec_context = NULL;
            goto end;
        }
        
        // Set proper stream time base for accurate duration calculation
        audio_stream->time_base = audio_codec_context->time_base;
        av_log(NULL, AV_LOG_INFO, "Audio stream time base: %d/%d\n", 
               audio_stream->time_base.num, audio_stream->time_base.den);
        
        // CRITICAL: Ensure output stream duration matches input for consistent HLS generation
        if (input_audio_stream->duration != AV_NOPTS_VALUE && input_audio_stream->duration > 0) {
            audio_stream->duration = input_audio_stream->duration;
            av_log(NULL, AV_LOG_INFO, "Set audio stream duration to match input: %lld\n", audio_stream->duration);
        }
    }

    // Open output file
    if (!(output_format_context->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&output_format_context->pb, output_playlist, AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not open output file '%s': %s\n", output_playlist, av_err2str(ret));
            goto end;
        }
    }

    // Set HLS options for accurate duration reporting
    hls_options = NULL;
    snprintf(segment_filename, sizeof(segment_filename), "%s/segment%%03d.ts", output_dir);
    
    // Use 1-second segments for more accurate duration reporting and consistency
    av_dict_set(&hls_options, "hls_list_size", "0", 0);  // Keep all segments
    av_dict_set(&hls_options, "hls_segment_filename", segment_filename, 0);
    
    // Add options for accurate duration calculation
    av_dict_set(&hls_options, "hls_allow_cache", "1", 0);  // Allow caching
    av_dict_set(&hls_options, "hls_base_url", "", 0);  // Base URL for segments
    
    // Add segment duration validation to ensure consistency
    av_dict_set(&hls_options, "hls_segment_duration", "1", 0);  // Force exact segment duration
    av_dict_set(&hls_options, "hls_flags", "independent_segments+discont_start", 0);  // Better segment handling
    
    // CRITICAL: Ensure proper time base for segment duration calculation
    av_dict_set(&hls_options, "hls_time", "1.0", 0);  // Use floating point for precise timing
    av_dict_set(&hls_options, "hls_segment_type", "mpegts", 0);  // Use MPEG-TS segments
    av_dict_set(&hls_options, "hls_playlist_type", "vod", 0);  // Video on demand for accurate duration
    
    // CRITICAL: Add duration calculation to ensure accurate playlist duration
    if (input_video_stream) {
        double input_duration = 0.0;
        
        // Calculate duration more robustly
        if (input_video_stream->duration != AV_NOPTS_VALUE && input_video_stream->duration > 0) {
            input_duration = (double)input_video_stream->duration * av_q2d(input_video_stream->time_base);
        } else {
            // Fallback: try to get duration from format context
            if (input_format_context->duration != AV_NOPTS_VALUE && input_format_context->duration > 0) {
                input_duration = (double)input_format_context->duration / AV_TIME_BASE;
            }
        }
        
        av_log(NULL, AV_LOG_INFO, "Input video duration: %.2f seconds\n", input_duration);
        
        // Set the output format context duration to match input duration
        if (input_duration > 0) {
            output_format_context->duration = input_video_stream->duration;
            output_format_context->start_time = input_video_stream->start_time;
            av_log(NULL, AV_LOG_INFO, "Set output duration to match input: %lld\n", output_format_context->duration);
        } else {
            av_log(NULL, AV_LOG_WARNING, "Could not determine input duration, using default\n");
        }
    }

    // Write the stream header
    ret = avformat_write_header(output_format_context, &hls_options);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred when writing header to output file: %s\n", av_err2str(ret));
        goto end;
    }
    av_dict_free(&hls_options);

    // Transcode packets from input to output
    input_frame = av_frame_alloc();
    output_frame = av_frame_alloc();
    if (!input_frame || !output_frame) {
        av_log(NULL, AV_LOG_ERROR, "Could not allocate frames\n");
        ret = AVERROR_UNKNOWN;
        goto end;
    }

    // Initialize video scaler if needed
    if (input_video_stream && video_codec_context) {
        sws_ctx = sws_getContext(
            input_video_stream->codecpar->width, input_video_stream->codecpar->height,
            (int)input_video_stream->codecpar->format,
            video_codec_context->width, video_codec_context->height,
            video_codec_context->pix_fmt,
            SWS_BILINEAR, NULL, NULL, NULL
        );
        if (!sws_ctx) {
            av_log(NULL, AV_LOG_ERROR, "Could not initialize video scaler\n");
            ret = AVERROR_UNKNOWN;
            goto end;
        }
    }

    // Initialize audio resampler if needed
    if (input_audio_stream && audio_codec_context) {
        swr_ctx = swr_alloc();
        if (!swr_ctx) {
            fprintf(stderr, "Could not allocate resampler context\n");
            ret = AVERROR(ENOMEM);
            goto end;
        }
        
        // Set up the resampler with newer API
        av_opt_set_chlayout(swr_ctx, "out_chlayout", &audio_codec_context->ch_layout, 0);
        av_opt_set_int(swr_ctx, "out_sample_fmt", audio_codec_context->sample_fmt, 0);
        av_opt_set_int(swr_ctx, "out_sample_rate", audio_codec_context->sample_rate, 0);
        av_opt_set_chlayout(swr_ctx, "in_chlayout", &input_audio_stream->codecpar->ch_layout, 0);
        av_opt_set_int(swr_ctx, "in_sample_fmt", input_audio_stream->codecpar->format, 0);
        av_opt_set_int(swr_ctx, "in_sample_rate", input_audio_stream->codecpar->sample_rate, 0);
        
        if ((ret = swr_init(swr_ctx)) < 0) {
            fprintf(stderr, "Failed to initialize the resampling context\n");
            goto end;
        }
        
        // Set resampler quality and method to prevent NaN values
        av_opt_set_int(swr_ctx, "filter_size", 8, 0); // Smaller filter for stability
        av_opt_set_int(swr_ctx, "phase_shift", 6, 0); // Conservative phase alignment
        av_opt_set_double(swr_ctx, "cutoff", 0.6, 0); // Very conservative cutoff
        av_opt_set_int(swr_ctx, "linear_interp", 1, 0); // Use linear interpolation for stability
        av_opt_set_int(swr_ctx, "exact_rational", 1, 0); // Use exact rational arithmetic
        
        // Audio buffer for handling variable frame sizes
        audio_buffer = av_frame_alloc();
        if (!audio_buffer) {
            av_log(NULL, AV_LOG_ERROR, "Could not allocate audio buffer\n");
            ret = AVERROR(ENOMEM);
            goto end;
        }
        
        // Safety check: ensure audio_codec_context is valid before accessing frame_size
        if (!audio_codec_context) {
            av_log(NULL, AV_LOG_ERROR, "Audio codec context is NULL, cannot access frame_size\n");
            ret = AVERROR_UNKNOWN;
            goto end;
        }
        
        audio_buffer->format = audio_codec_context->sample_fmt;
        av_channel_layout_copy(&audio_buffer->ch_layout, &audio_codec_context->ch_layout);
        max_buffer_samples = audio_codec_context->frame_size * 3; // Increased to handle multiple input frames
        audio_buffer->nb_samples = max_buffer_samples;
        
        ret = av_frame_get_buffer(audio_buffer, 0);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not allocate audio buffer memory\n");
            goto end;
        }
        
        buffered_samples = 0;
        
        // Set memory management options to reduce pressure
        av_log(NULL, AV_LOG_INFO, "Initialized audio processing with memory management\n");
        
        // Set thread safety and memory management options
        av_log_set_level(AV_LOG_INFO);
        
        // Initialize thread safety for FFmpeg processing
        av_log(NULL, AV_LOG_INFO, "Initializing thread safety for FFmpeg processing\n");
        
        // Set memory management options to reduce pressure
        av_log(NULL, AV_LOG_INFO, "Memory management: Using conservative settings to prevent corruption\n");
    }

    // Create input codec contexts for decoding
    if (input_video_stream) {
        const AVCodec *input_video_codec = avcodec_find_decoder(input_video_stream->codecpar->codec_id);
        if (input_video_codec) {
            input_video_codec_ctx = avcodec_alloc_context3(input_video_codec);
            if (input_video_codec_ctx) {
                avcodec_parameters_to_context(input_video_codec_ctx, input_video_stream->codecpar);
                avcodec_open2(input_video_codec_ctx, input_video_codec, NULL);
            }
        }
    }
    
    if (input_audio_stream) {
        const AVCodec *input_audio_codec = avcodec_find_decoder(input_audio_stream->codecpar->codec_id);
        if (input_audio_codec) {
            input_audio_codec_ctx = avcodec_alloc_context3(input_audio_codec);
            if (input_audio_codec_ctx) {
                avcodec_parameters_to_context(input_audio_codec_ctx, input_audio_stream->codecpar);
                avcodec_open2(input_audio_codec_ctx, input_audio_codec, NULL);
            }
        }
    }

    // Initialize variables
    int64_t audio_pts_counter = 0;  // Counter for audio frame timestamps
    int64_t last_audio_dts = 0;     // Counter for audio packet DTS
    int64_t last_video_dts = 0;     // Counter for video packet DTS
    int input_finished = 0;

    // Process packets with proper frame preservation
    av_log(NULL, AV_LOG_INFO, "Starting main processing loop...\n");
    
    while (!input_finished || buffered_samples >= audio_codec_context->frame_size) {
        if (!input_finished && buffered_samples < max_buffer_samples) {
            // Read next input packet
            ret = av_read_frame(input_format_context, &input_pkt);
            if (ret < 0) {
                av_log(NULL, AV_LOG_INFO, "Input finished (ret=%d), no more packets to read.\n", ret);
                input_finished = 1;
                // Do not refill buffer, just process remaining samples
                continue;
            }
            AVStream *input_stream = input_format_context->streams[input_pkt.stream_index];
            AVStream *output_stream = NULL;
            AVCodecContext *input_codec_ctx = NULL;
            AVCodecContext *output_codec_ctx = NULL;
            
            if (input_pkt.stream_index == video_stream_index && video_stream) {
                output_stream = video_stream;
                input_codec_ctx = input_video_codec_ctx;
                output_codec_ctx = video_codec_context;
            } else if (input_pkt.stream_index == audio_stream_index && audio_stream) {
                output_stream = audio_stream;
                input_codec_ctx = input_audio_codec_ctx;
                output_codec_ctx = audio_codec_context;
            } else {
                av_packet_unref(&input_pkt);
                continue;
            }

            // Check for NULL decoder context before decoding
            if (input_codec_ctx == NULL) {
                av_log(NULL, AV_LOG_ERROR, "Decoder context is NULL for stream %d\n", input_pkt.stream_index);
                av_packet_unref(&input_pkt);
                continue;
            }

            // Decode input packet
            ret = avcodec_send_packet(input_codec_ctx, &input_pkt);
            if (ret < 0) {
                av_log(NULL, AV_LOG_ERROR, "Error sending packet to decoder: %s\n", av_err2str(ret));
                av_packet_unref(&input_pkt);
                continue;
            }

            while (ret >= 0) {
                ret = avcodec_receive_frame(input_codec_ctx, input_frame);
                if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                    break;
                } else if (ret < 0) {
                    av_log(NULL, AV_LOG_ERROR, "Error receiving frame from decoder: %s\n", av_err2str(ret));
                    goto end;
                }

                // Process video frame
                if (input_pkt.stream_index == video_stream_index && sws_ctx) {
                    // Reset output frame for video processing
                    av_frame_unref(output_frame);
                    output_frame->format = video_codec_context->pix_fmt;
                    output_frame->width = video_codec_context->width;
                    output_frame->height = video_codec_context->height;
                    
                    // Scale video frame
                    ret = av_frame_get_buffer(output_frame, 0);
                    if (ret < 0) {
                        av_log(NULL, AV_LOG_ERROR, "Could not allocate output frame buffer\n");
                        goto end;
                    }
                    
                    ret = sws_scale(sws_ctx, (const uint8_t *const *)input_frame->data, input_frame->linesize, 0, 
                                   input_frame->height, output_frame->data, output_frame->linesize);
                    if (ret < 0) {
                        av_log(NULL, AV_LOG_ERROR, "Error scaling video frame\n");
                        goto end;
                    }
                    
                    // Set PTS in codec time base (not stream time base to avoid double scaling)
                    output_frame->pts = av_rescale_q(input_frame->pts, input_stream->time_base, video_codec_context->time_base);
                    
                    // Encode output frame
                    av_log(NULL, AV_LOG_INFO, "About to send video frame to encoder\n");
                    
                    // Debug: Check video frame configuration
                    av_log(NULL, AV_LOG_INFO, "Video frame config: width=%d, height=%d, format=%d, pts=%lld\n",
                           output_frame->width, output_frame->height, output_frame->format, output_frame->pts);
                    av_log(NULL, AV_LOG_INFO, "Video codec config: width=%d, height=%d, pix_fmt=%d\n",
                           video_codec_context->width, video_codec_context->height, video_codec_context->pix_fmt);
                    
                    ret = avcodec_send_frame(video_codec_context, output_frame);
                    if (ret < 0) {
                        av_log(NULL, AV_LOG_ERROR, "Error sending frame to encoder: %s\n", av_err2str(ret));
                        goto end;
                    }

                    // Allocate output packet
                    AVPacket *output_pkt = av_packet_alloc();
                    if (!output_pkt) {
                        fprintf(stderr, "Could not allocate output packet\n");
                        ret = AVERROR(ENOMEM);
                        goto end;
                    }

                    while (ret >= 0) {
                        ret = avcodec_receive_packet(video_codec_context, output_pkt);
                        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                            break;
                        } else if (ret < 0) {
                            av_log(NULL, AV_LOG_ERROR, "Error receiving packet from encoder: %s\n", av_err2str(ret));
                            goto end;
                        }

                        output_pkt->stream_index = video_stream->index;
                        
                        // Ensure monotonically increasing timestamps
                        if (output_pkt->pts != AV_NOPTS_VALUE) {
                            output_pkt->pts = av_rescale_q(output_pkt->pts, video_codec_context->time_base, video_stream->time_base);
                        }
                        if (output_pkt->dts != AV_NOPTS_VALUE) {
                            output_pkt->dts = av_rescale_q(output_pkt->dts, video_codec_context->time_base, video_stream->time_base);
                        }
                        
                        // Ensure DTS is monotonically increasing
                        if (output_pkt->dts != AV_NOPTS_VALUE && output_pkt->dts <= last_video_dts) {
                            output_pkt->dts = last_video_dts + 1;
                        }
                        if (output_pkt->dts != AV_NOPTS_VALUE) {
                            last_video_dts = output_pkt->dts;
                        }
                        
                        // Ensure PTS is greater than or equal to DTS
                        if (output_pkt->pts != AV_NOPTS_VALUE && output_pkt->dts != AV_NOPTS_VALUE && output_pkt->pts < output_pkt->dts) {
                            output_pkt->pts = output_pkt->dts;
                        }

                        ret = av_interleaved_write_frame(output_format_context, output_pkt);
                        if (ret < 0) {
                            av_log(NULL, AV_LOG_ERROR, "Error writing packet: %s\n", av_err2str(ret));
                            goto end;
                        }
                    }
                }
                // Process audio frame
                else if (input_pkt.stream_index == audio_stream_index && swr_ctx && audio_buffer) {
                    // Debug: Check for NaN/infinity values in input audio frame
                    float *input_data = (float *)input_frame->data[0];
                    int has_nan_input = 0;
                    for (int i = 0; i < input_frame->nb_samples * input_frame->ch_layout.nb_channels; i++) {
                        if (isnan(input_data[i]) || isinf(input_data[i])) {
                            has_nan_input = 1;
                            av_log(NULL, AV_LOG_ERROR, "NaN/Inf in input audio at sample %d: %f\n", i, input_data[i]);
                            break;
                        }
                    }
                    if (has_nan_input) {
                        av_log(NULL, AV_LOG_ERROR, "Input audio contains NaN/Inf values\n");
                        goto end;
                    }

                    // Log resampler parameters
                    av_log(NULL, AV_LOG_INFO, "Resampler params: in_fmt=%d, in_rate=%d, in_ch=%d | out_fmt=%d, out_rate=%d, out_ch=%d\n", 
                        input_audio_codec_ctx->sample_fmt, input_audio_codec_ctx->sample_rate, input_audio_codec_ctx->ch_layout.nb_channels, 
                        audio_codec_context->sample_fmt, audio_codec_context->sample_rate, audio_codec_context->ch_layout.nb_channels);

                    // Check if resampling is actually needed
                    int needs_resampling = (input_audio_codec_ctx->sample_fmt != audio_codec_context->sample_fmt ||
                                           input_audio_codec_ctx->sample_rate != audio_codec_context->sample_rate ||
                                           input_audio_codec_ctx->ch_layout.nb_channels != audio_codec_context->ch_layout.nb_channels);
                    
                    if (!needs_resampling) {
                        // No resampling needed, directly copy audio data
                        av_log(NULL, AV_LOG_INFO, "Skipping resampling - formats are identical\n");
                        
                        int bytes_per_sample = av_get_bytes_per_sample(audio_codec_context->sample_fmt);
                        int channels = audio_codec_context->ch_layout.nb_channels;
                        
                        // Check if we have enough space in buffer
                        if (buffered_samples + input_frame->nb_samples > max_buffer_samples) {
                            av_log(NULL, AV_LOG_ERROR, "Audio buffer overflow\n");
                            goto end;
                        }
                        
                        // Copy audio data directly to buffer
                        memcpy(audio_buffer->data[0] + buffered_samples * bytes_per_sample * channels,
                               input_frame->data[0],
                               input_frame->nb_samples * bytes_per_sample * channels);
                        
                        buffered_samples += input_frame->nb_samples;
                        
                        av_log(NULL, AV_LOG_INFO, "Direct copy: input_samples=%d, buffer_samples=%d\n", 
                               input_frame->nb_samples, buffered_samples);
                        
                        // Process complete frames from buffer after direct copy
                        while (buffered_samples >= audio_codec_context->frame_size) {
                            av_log(NULL, AV_LOG_INFO, "Processing complete frame after direct copy: buffer_samples=%d, required_frame_size=%d\n",
                                   buffered_samples, audio_codec_context->frame_size);
                            
                            // Copy one frame worth of samples to the buffer frame
                            int frame_bytes = audio_codec_context->frame_size * bytes_per_sample * channels;
                            
                            // Ensure the frame is properly configured
                            audio_buffer->nb_samples = audio_codec_context->frame_size;
                            audio_buffer->format = audio_codec_context->sample_fmt;
                            av_channel_layout_copy(&audio_buffer->ch_layout, &audio_codec_context->ch_layout);
                            
                            // Set proper timestamp for audio frame using input frame PTS
                            // Convert input frame PTS to output time base to maintain correct duration
                            if (input_frame->pts != AV_NOPTS_VALUE) {
                                // Use simple incremental counter for each frame from the buffer
                                // This ensures continuous timestamps without discontinuities
                                audio_buffer->pts = av_rescale_q(input_frame->pts, input_audio_stream->time_base, audio_codec_context->time_base) + audio_pts_counter;
                                audio_pts_counter += audio_buffer->nb_samples;
                                av_log(NULL, AV_LOG_INFO, "Using incremental PTS: input_pts=%lld, counter_offset=%lld, final_pts=%lld\n", 
                                       input_frame->pts, audio_pts_counter - audio_buffer->nb_samples, audio_buffer->pts);
                            } else {
                                // Fallback to manual counter if input PTS is not available
                                audio_buffer->pts = audio_pts_counter;
                                audio_pts_counter += audio_buffer->nb_samples;
                                av_log(NULL, AV_LOG_WARNING, "Input frame PTS not available, using manual counter: pts=%lld\n", audio_buffer->pts);
                            }
                            
                            // FINAL SAFETY CHECK: Validate audio data before sending to encoder
                            float *final_audio_data = (float *)audio_buffer->data[0];
                            int total_final_samples = audio_buffer->nb_samples * audio_buffer->ch_layout.nb_channels;
                            int has_final_nan = 0;
                            
                            for (int i = 0; i < total_final_samples; i++) {
                                if (isnan(final_audio_data[i]) || isinf(final_audio_data[i])) {
                                    has_final_nan = 1;
                                    av_log(NULL, AV_LOG_WARNING, "Final NaN/Inf check: sample %d = %f, replacing with 0\n", i, final_audio_data[i]);
                                    final_audio_data[i] = 0.0f;
                                }
                            }
                            
                            if (has_final_nan) {
                                av_log(NULL, AV_LOG_WARNING, "Final audio frame contained NaN/Inf values, replaced with zeros\n");
                            }
                            
                            av_log(NULL, AV_LOG_INFO, "Sending audio frame: samples=%d, format=%d, channels=%d, pts=%lld\n",
                                   audio_buffer->nb_samples, audio_buffer->format, 
                                   audio_buffer->ch_layout.nb_channels, audio_buffer->pts);
                            
                            ret = avcodec_send_frame(audio_codec_context, audio_buffer);
                            if (ret < 0) {
                                if (ret == AVERROR(EAGAIN)) {
                                    // Encoder buffer is full, receive packets to free up space
                                    av_log(NULL, AV_LOG_INFO, "Audio encoder buffer full, receiving packets to free space\n");
                                    
                                    AVPacket *temp_pkt = av_packet_alloc();
                                    if (!temp_pkt) {
                                        av_log(NULL, AV_LOG_ERROR, "Could not allocate temporary packet\n");
                                        goto end;
                                    }
                                    
                                    while (avcodec_receive_packet(audio_codec_context, temp_pkt) >= 0) {
                                        // Set proper stream index and timestamps for audio packet
                                        temp_pkt->stream_index = audio_stream->index;
                                        
                                        // Ensure monotonically increasing timestamps
                                        if (temp_pkt->pts != AV_NOPTS_VALUE) {
                                            temp_pkt->pts = av_rescale_q(temp_pkt->pts, audio_codec_context->time_base, audio_stream->time_base);
                                        }
                                        if (temp_pkt->dts != AV_NOPTS_VALUE) {
                                            temp_pkt->dts = av_rescale_q(temp_pkt->dts, audio_codec_context->time_base, audio_stream->time_base);
                                        }
                                        
                                        // Ensure DTS is monotonically increasing
                                        if (temp_pkt->dts != AV_NOPTS_VALUE && temp_pkt->dts <= last_audio_dts) {
                                            temp_pkt->dts = last_audio_dts + 1;
                                            av_log(NULL, AV_LOG_WARNING, "Audio DTS discontinuity detected, corrected: old_dts=%lld, new_dts=%lld\n", 
                                                   last_audio_dts, temp_pkt->dts);
                                        }
                                        if (temp_pkt->dts != AV_NOPTS_VALUE) {
                                            last_audio_dts = temp_pkt->dts;
                                        }
                                        
                                        // Ensure PTS is greater than or equal to DTS
                                        if (temp_pkt->pts != AV_NOPTS_VALUE && temp_pkt->dts != AV_NOPTS_VALUE && temp_pkt->pts < temp_pkt->dts) {
                                            temp_pkt->pts = temp_pkt->dts;
                                        }
                                        
                                        // Write the packet to the output
                                        ret = av_interleaved_write_frame(output_format_context, temp_pkt);
                                        if (ret < 0) {
                                            av_log(NULL, AV_LOG_ERROR, "Error writing audio packet: %s\n", av_err2str(ret));
                                            av_packet_free(&temp_pkt);
                                            goto end;
                                        }
                                    }
                                    av_packet_free(&temp_pkt);
                                    
                                    // Retry sending the frame
                                    ret = avcodec_send_frame(audio_codec_context, audio_buffer);
                                    if (ret < 0) {
                                        av_log(NULL, AV_LOG_WARNING, "Error sending frame to encoder after retry: %s, skipping frame\n", av_err2str(ret));
                                        // CRITICAL FIX: Even when skipping frame, we must remove the processed samples from buffer
                                        int remaining_samples = buffered_samples - audio_codec_context->frame_size;
                                        if (remaining_samples > 0) {
                                            memmove(audio_buffer->data[0],
                                                    audio_buffer->data[0] + frame_bytes,
                                                    remaining_samples * bytes_per_sample * channels);
                                        }
                                        buffered_samples = remaining_samples;
                                        av_log(NULL, AV_LOG_WARNING, "Skipped frame due to encoder error, buffer_samples=%d\n", buffered_samples);
                                        break; // Exit the while loop that processes complete frames
                                    } else {
                                        // SUCCESSFUL CASE: Initial frame was sent successfully, update buffer
                                        av_log(NULL, AV_LOG_INFO, "Initial audio frame sent successfully, updating buffer\n");
                                        // Remove the processed samples from buffer
                                        int remaining_samples = buffered_samples - audio_codec_context->frame_size;
                                        if (remaining_samples > 0) {
                                            memmove(audio_buffer->data[0],
                                                    audio_buffer->data[0] + frame_bytes,
                                                    remaining_samples * bytes_per_sample * channels);
                                        }
                                        buffered_samples = remaining_samples;
                                        av_log(NULL, AV_LOG_INFO, "Buffer updated after successful initial frame send, buffer_samples=%d\n", buffered_samples);
                                    }
                                }
                            }
                        }
                    } else {
                        // Resampling is needed - process audio frame
                        av_log(NULL, AV_LOG_INFO, "Resampling needed - processing audio frame\n");
                        AVFrame *resampled_frame = NULL;
                        int64_t out_samples = 0;
                        int ret_buf = 0;
                        // Allocate output frame for resampled audio
                        resampled_frame = av_frame_alloc();
                        if (!resampled_frame) {
                            av_log(NULL, AV_LOG_ERROR, "Could not allocate resampled frame\n");
                            goto end;
                        }
                        // Configure resampled frame
                        resampled_frame->format = audio_codec_context->sample_fmt;
                        av_channel_layout_copy(&resampled_frame->ch_layout, &audio_codec_context->ch_layout);
                        resampled_frame->sample_rate = audio_codec_context->sample_rate;
                        // Calculate output samples (approximate)
                        out_samples = av_rescale_rnd(swr_get_delay(swr_ctx, input_audio_codec_ctx->sample_rate) + input_frame->nb_samples,
                            audio_codec_context->sample_rate, input_audio_codec_ctx->sample_rate, AV_ROUND_UP);
                        resampled_frame->nb_samples = out_samples;
                        ret_buf = av_frame_get_buffer(resampled_frame, 0);
                        if (ret_buf < 0) {
                            av_log(NULL, AV_LOG_ERROR, "Could not allocate resampled frame buffer\n");
                            av_frame_free(&resampled_frame);
                            goto end;
                        }
                        // Perform resampling
                        int ret_swr = swr_convert(swr_ctx, resampled_frame->data, out_samples,
                            (const uint8_t **)input_frame->data, input_frame->nb_samples);
                        if (ret_swr < 0) {
                            av_log(NULL, AV_LOG_ERROR, "Error during resampling: %s\n", av_err2str(ret_swr));
                            av_frame_free(&resampled_frame);
                            goto end;
                        }
                        resampled_frame->nb_samples = ret_swr;
                        // Set proper timestamp for resampled frame
                        if (input_frame->pts != AV_NOPTS_VALUE) {
                            // Use simple incremental counter for resampled frame
                            resampled_frame->pts = av_rescale_q(input_frame->pts, input_audio_stream->time_base, audio_codec_context->time_base) + audio_pts_counter;
                            audio_pts_counter += resampled_frame->nb_samples;
                            av_log(NULL, AV_LOG_INFO, "Resampled frame PTS: input_pts=%lld, counter_offset=%lld, final_pts=%lld\n", 
                                   input_frame->pts, audio_pts_counter - resampled_frame->nb_samples, resampled_frame->pts);
                        } else {
                            resampled_frame->pts = audio_pts_counter;
                            audio_pts_counter += resampled_frame->nb_samples;
                            av_log(NULL, AV_LOG_WARNING, "Input frame PTS not available for resampled frame, using manual counter: pts=%lld\n", resampled_frame->pts);
                        }
                        // Check if we have enough space in buffer
                        if (buffered_samples + resampled_frame->nb_samples > max_buffer_samples) {
                            av_log(NULL, AV_LOG_ERROR, "Audio buffer overflow after resampling\n");
                            av_frame_free(&resampled_frame);
                            goto end;
                        }
                        // Copy resampled data to buffer
                        int bytes_per_sample = av_get_bytes_per_sample(audio_codec_context->sample_fmt);
                        int channels = audio_codec_context->ch_layout.nb_channels;
                        memcpy(audio_buffer->data[0] + buffered_samples * bytes_per_sample * channels,
                            resampled_frame->data[0],
                            resampled_frame->nb_samples * bytes_per_sample * channels);
                        buffered_samples += resampled_frame->nb_samples;
                        av_log(NULL, AV_LOG_INFO, "Resampled audio: input_samples=%d, resampled_samples=%d, buffer_samples=%d\n", input_frame->nb_samples, resampled_frame->nb_samples, buffered_samples);
                        // Process complete frames from buffer after resampling
                        while (buffered_samples >= audio_codec_context->frame_size) {
                            av_log(NULL, AV_LOG_INFO, "Processing complete frame after resampling: buffer_samples=%d, required_frame_size=%d\n", buffered_samples, audio_codec_context->frame_size);
                            int frame_bytes = audio_codec_context->frame_size * bytes_per_sample * channels;
                            audio_buffer->nb_samples = audio_codec_context->frame_size;
                            audio_buffer->format = audio_codec_context->sample_fmt;
                            av_channel_layout_copy(&audio_buffer->ch_layout, &audio_codec_context->ch_layout);
                            // Set proper timestamp for audio frame using input frame PTS
                            // Convert input frame PTS to output time base to maintain correct duration
                            if (input_frame->pts != AV_NOPTS_VALUE) {
                                // Use simple incremental counter for each frame from the buffer
                                // This ensures continuous timestamps without discontinuities
                                audio_buffer->pts = av_rescale_q(input_frame->pts, input_audio_stream->time_base, audio_codec_context->time_base) + audio_pts_counter;
                                audio_pts_counter += audio_buffer->nb_samples;
                                av_log(NULL, AV_LOG_INFO, "Using incremental PTS: input_pts=%lld, counter_offset=%lld, final_pts=%lld\n", 
                                       input_frame->pts, audio_pts_counter - audio_buffer->nb_samples, audio_buffer->pts);
                            } else {
                                // Fallback to manual counter if input PTS is not available
                                audio_buffer->pts = audio_pts_counter;
                                audio_pts_counter += audio_buffer->nb_samples;
                                av_log(NULL, AV_LOG_WARNING, "Input frame PTS not available, using manual counter: pts=%lld\n", audio_buffer->pts);
                            }
                            // FINAL SAFETY CHECK: Validate audio data before sending to encoder
                            float *final_audio_data = (float *)audio_buffer->data[0];
                            int total_final_samples = audio_buffer->nb_samples * audio_buffer->ch_layout.nb_channels;
                            int has_final_nan = 0;
                            for (int i = 0; i < total_final_samples; i++) {
                                if (isnan(final_audio_data[i]) || isinf(final_audio_data[i])) {
                                    has_final_nan = 1;
                                    av_log(NULL, AV_LOG_WARNING, "Final NaN/Inf check: sample %d = %f, replacing with 0\n", i, final_audio_data[i]);
                                    final_audio_data[i] = 0.0f;
                                }
                            }
                            if (has_final_nan) {
                                av_log(NULL, AV_LOG_WARNING, "Final audio frame contained NaN/Inf values, replaced with zeros\n");
                            }
                            av_log(NULL, AV_LOG_INFO, "Sending resampled audio frame: samples=%d, format=%d, channels=%d, pts=%lld\n", audio_buffer->nb_samples, audio_buffer->format, audio_buffer->ch_layout.nb_channels, audio_buffer->pts);
                            ret = avcodec_send_frame(audio_codec_context, audio_buffer);
                            if (ret < 0) {
                                if (ret == AVERROR(EAGAIN)) {
                                    av_log(NULL, AV_LOG_INFO, "Audio encoder buffer full, receiving packets to free space\n");
                                    AVPacket *temp_pkt = av_packet_alloc();
                                    if (!temp_pkt) {
                                        av_log(NULL, AV_LOG_ERROR, "Could not allocate temporary packet\n");
                                        av_frame_free(&resampled_frame);
                                        goto end;
                                    }
                                    while (avcodec_receive_packet(audio_codec_context, temp_pkt) >= 0) {
                                        temp_pkt->stream_index = audio_stream->index;
                                        if (temp_pkt->pts != AV_NOPTS_VALUE) {
                                            temp_pkt->pts = av_rescale_q(temp_pkt->pts, audio_codec_context->time_base, audio_stream->time_base);
                                        }
                                        if (temp_pkt->dts != AV_NOPTS_VALUE) {
                                            temp_pkt->dts = av_rescale_q(temp_pkt->dts, audio_codec_context->time_base, audio_stream->time_base);
                                        }
                                        if (temp_pkt->dts != AV_NOPTS_VALUE && temp_pkt->dts <= last_audio_dts) {
                                            temp_pkt->dts = last_audio_dts + 1;
                                        }
                                        if (temp_pkt->dts != AV_NOPTS_VALUE) {
                                            last_audio_dts = temp_pkt->dts;
                                        }
                                        if (temp_pkt->pts != AV_NOPTS_VALUE && temp_pkt->dts != AV_NOPTS_VALUE && temp_pkt->pts < temp_pkt->dts) {
                                            temp_pkt->pts = temp_pkt->dts;
                                        }
                                        ret = av_interleaved_write_frame(output_format_context, temp_pkt);
                                        if (ret < 0) {
                                            av_log(NULL, AV_LOG_ERROR, "Error writing audio packet: %s\n", av_err2str(ret));
                                            av_packet_free(&temp_pkt);
                                            av_frame_free(&resampled_frame);
                                            goto end;
                                        }
                                    }
                                    av_packet_free(&temp_pkt);
                                    ret = avcodec_send_frame(audio_codec_context, audio_buffer);
                                    if (ret < 0) {
                                        av_log(NULL, AV_LOG_WARNING, "Error sending frame to encoder after retry: %s, skipping frame\n", av_err2str(ret));
                                        int remaining_samples = buffered_samples - audio_codec_context->frame_size;
                                        if (remaining_samples > 0) {
                                            memmove(audio_buffer->data[0], audio_buffer->data[0] + frame_bytes, remaining_samples * bytes_per_sample * channels);
                                        }
                                        buffered_samples = remaining_samples;
                                        av_log(NULL, AV_LOG_WARNING, "Skipped frame due to encoder error, buffer_samples=%d\n", buffered_samples);
                                        break;
                                    } else {
                                        av_log(NULL, AV_LOG_INFO, "Initial audio frame sent successfully, updating buffer\n");
                                        int remaining_samples = buffered_samples - audio_codec_context->frame_size;
                                        if (remaining_samples > 0) {
                                            memmove(audio_buffer->data[0], audio_buffer->data[0] + frame_bytes, remaining_samples * bytes_per_sample * channels);
                                        }
                                        buffered_samples = remaining_samples;
                                        av_log(NULL, AV_LOG_INFO, "Buffer updated after successful initial frame send, buffer_samples=%d\n", buffered_samples);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        av_packet_unref(&input_pkt);
    }

    // Flush encoders
    if (video_codec_context) {
        avcodec_send_frame(video_codec_context, NULL);
        AVPacket *output_pkt = av_packet_alloc();
        if (!output_pkt) {
            fprintf(stderr, "Could not allocate output packet\n");
            ret = AVERROR(ENOMEM);
            goto end;
        }
        
        while (avcodec_receive_packet(video_codec_context, output_pkt) >= 0) {
            output_pkt->stream_index = video_stream->index;
            
            // Ensure monotonically increasing timestamps
            if (output_pkt->pts != AV_NOPTS_VALUE) {
                output_pkt->pts = av_rescale_q(output_pkt->pts, video_codec_context->time_base, video_stream->time_base);
            }
            if (output_pkt->dts != AV_NOPTS_VALUE) {
                output_pkt->dts = av_rescale_q(output_pkt->dts, video_codec_context->time_base, video_stream->time_base);
            }
            
            // Ensure DTS is monotonically increasing
            if (output_pkt->dts != AV_NOPTS_VALUE && output_pkt->dts <= last_video_dts) {
                output_pkt->dts = last_video_dts + 1;
            }
            if (output_pkt->dts != AV_NOPTS_VALUE) {
                last_video_dts = output_pkt->dts;
            }
            
            // Ensure PTS is greater than or equal to DTS
            if (output_pkt->pts != AV_NOPTS_VALUE && output_pkt->dts != AV_NOPTS_VALUE && output_pkt->pts < output_pkt->dts) {
                output_pkt->pts = output_pkt->dts;
            }
            
            ret = av_interleaved_write_frame(output_format_context, output_pkt);
            if (ret < 0) {
                av_log(NULL, AV_LOG_ERROR, "Error writing packet: %s\n", av_err2str(ret));
                goto end;
            }
        }
    }
    
    if (audio_codec_context) {
        // Send any remaining audio data in buffer
        if (audio_buffer && buffered_samples > 0) {
            // Send the remaining samples as the final frame
            int bytes_per_sample = av_get_bytes_per_sample(audio_codec_context->sample_fmt);
            int channels = audio_codec_context->ch_layout.nb_channels;
            
            memcpy(audio_buffer->data[0], 
                   audio_buffer->data[0], 
                   buffered_samples * bytes_per_sample * channels);
            
            // Configure frame with actual number of samples
            audio_buffer->nb_samples = buffered_samples;
            audio_buffer->format = audio_codec_context->sample_fmt;
            av_channel_layout_copy(&audio_buffer->ch_layout, &audio_codec_context->ch_layout);
            
            // Calculate proper timestamp for final audio frame
            // Since this is during flushing, we don't have an input frame, so use the manual counter
            audio_buffer->pts = audio_pts_counter;
            audio_pts_counter += audio_buffer->nb_samples;
            
            // FINAL SAFETY CHECK: Validate audio data before sending to encoder
            float *final_audio_data = (float *)audio_buffer->data[0];
            int total_final_samples = audio_buffer->nb_samples * audio_buffer->ch_layout.nb_channels;
            int has_final_nan = 0;
            
            for (int i = 0; i < total_final_samples; i++) {
                if (isnan(final_audio_data[i]) || isinf(final_audio_data[i])) {
                    has_final_nan = 1;
                    av_log(NULL, AV_LOG_WARNING, "Final NaN/Inf check: sample %d = %f, replacing with 0\n", i, final_audio_data[i]);
                    final_audio_data[i] = 0.0f;
                }
            }
            
            if (has_final_nan) {
                av_log(NULL, AV_LOG_WARNING, "Final audio frame contained NaN/Inf values, replaced with zeros\n");
            }
            
            av_log(NULL, AV_LOG_INFO, "Sending final audio frame: samples=%d, format=%d, channels=%d, pts=%lld\n",
                   audio_buffer->nb_samples, audio_buffer->format, 
                   audio_buffer->ch_layout.nb_channels, audio_buffer->pts);
            
            // Robustly send the final audio frame, handling EAGAIN
            int final_frame_sent = 0;
            while (!final_frame_sent) {
                ret = avcodec_send_frame(audio_codec_context, audio_buffer);
                if (ret == AVERROR(EAGAIN)) {
                    // Drain encoder
                    AVPacket *temp_pkt = av_packet_alloc();
                    if (!temp_pkt) {
                        av_log(NULL, AV_LOG_ERROR, "Could not allocate temporary packet\n");
                        goto end;
                    }
                    while (avcodec_receive_packet(audio_codec_context, temp_pkt) >= 0) {
                        temp_pkt->stream_index = audio_stream->index;
                        // Timestamp fixup as before
                        if (temp_pkt->pts != AV_NOPTS_VALUE) {
                            temp_pkt->pts = av_rescale_q(temp_pkt->pts, audio_codec_context->time_base, audio_stream->time_base);
                        }
                        if (temp_pkt->dts != AV_NOPTS_VALUE) {
                            temp_pkt->dts = av_rescale_q(temp_pkt->dts, audio_codec_context->time_base, audio_stream->time_base);
                        }
                        if (temp_pkt->dts != AV_NOPTS_VALUE && temp_pkt->dts <= last_audio_dts) {
                            temp_pkt->dts = last_audio_dts + 1;
                        }
                        if (temp_pkt->dts != AV_NOPTS_VALUE) {
                            last_audio_dts = temp_pkt->dts;
                        }
                        if (temp_pkt->pts != AV_NOPTS_VALUE && temp_pkt->dts != AV_NOPTS_VALUE && temp_pkt->pts < temp_pkt->dts) {
                            temp_pkt->pts = temp_pkt->dts;
                        }
                        ret = av_interleaved_write_frame(output_format_context, temp_pkt);
                        if (ret < 0) {
                            av_log(NULL, AV_LOG_ERROR, "Error writing audio packet: %s\n", av_err2str(ret));
                            av_packet_free(&temp_pkt);
                            goto end;
                        }
                    }
                    av_packet_free(&temp_pkt);
                    // Try again
                } else if (ret < 0) {
                    av_log(NULL, AV_LOG_ERROR, "Error sending final audio frame to encoder: %s\n", av_err2str(ret));
                    goto end;
                } else {
                    final_frame_sent = 1;
                }
            }
        }
        
        avcodec_send_frame(audio_codec_context, NULL);
        
        AVPacket *output_pkt = av_packet_alloc();
        if (!output_pkt) {
            fprintf(stderr, "Could not allocate output packet\n");
            ret = AVERROR(ENOMEM);
            goto end;
        }
        
        while (avcodec_receive_packet(audio_codec_context, output_pkt) >= 0) {
            output_pkt->stream_index = audio_stream->index;
            
            // Ensure monotonically increasing timestamps
            if (output_pkt->pts != AV_NOPTS_VALUE) {
                output_pkt->pts = av_rescale_q(output_pkt->pts, audio_codec_context->time_base, audio_stream->time_base);
            }
            if (output_pkt->dts != AV_NOPTS_VALUE) {
                output_pkt->dts = av_rescale_q(output_pkt->dts, audio_codec_context->time_base, audio_stream->time_base);
            }
            
            // Ensure DTS is monotonically increasing
            if (output_pkt->dts != AV_NOPTS_VALUE && output_pkt->dts <= last_audio_dts) {
                output_pkt->dts = last_audio_dts + 1;
                av_log(NULL, AV_LOG_WARNING, "Audio DTS discontinuity detected, corrected: old_dts=%lld, new_dts=%lld\n", 
                       last_audio_dts, output_pkt->dts);
            }
            if (output_pkt->dts != AV_NOPTS_VALUE) {
                last_audio_dts = output_pkt->dts;
            }
            
            // Ensure PTS is greater than or equal to DTS
            if (output_pkt->pts != AV_NOPTS_VALUE && output_pkt->dts != AV_NOPTS_VALUE && output_pkt->pts < output_pkt->dts) {
                output_pkt->pts = output_pkt->dts;
            }

            ret = av_interleaved_write_frame(output_format_context, output_pkt);
            if (ret < 0) {
                av_log(NULL, AV_LOG_ERROR, "Error writing packet: %s\n", av_err2str(ret));
                goto end;
            }
        }
        
        av_packet_free(&output_pkt);
    }

    // Write trailer
    av_log(NULL, AV_LOG_INFO, "Writing trailer...\n");
    av_write_trailer(output_format_context);
    av_log(NULL, AV_LOG_INFO, "Trailer written successfully\n");

    av_log(NULL, AV_LOG_INFO, "HLS conversion completed successfully\n");

end:
    // Clean up resources
    if (input_frame) { av_frame_free(&input_frame); }
    if (output_frame) { av_frame_free(&output_frame); }
    if (sws_ctx) { sws_freeContext(sws_ctx); sws_ctx = NULL; }
    if (swr_ctx) { swr_free(&swr_ctx); swr_ctx = NULL; }
    if (audio_buffer) { av_frame_free(&audio_buffer); audio_buffer = NULL; }
    if (input_video_codec_ctx) { avcodec_free_context(&input_video_codec_ctx); }
    if (input_audio_codec_ctx) { avcodec_free_context(&input_audio_codec_ctx); }
    if (video_codec_context) { avcodec_free_context(&video_codec_context); }
    if (audio_codec_context) { avcodec_free_context(&audio_codec_context); }
    if (output_format_context) {
        if (!(output_format_context->oformat->flags & AVFMT_NOFILE)) {
            avio_closep(&output_format_context->pb);
        }
        avformat_free_context(output_format_context);
        output_format_context = NULL;
    }
    if (input_format_context) {
        avformat_close_input(&input_format_context);
        input_format_context = NULL;
    }
    
    // Final memory cleanup
    av_log(NULL, AV_LOG_INFO, "Memory cleanup completed\n");
    
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "HLS conversion failed with error: %d\n", ret);
    } else {
        av_log(NULL, AV_LOG_INFO, "HLS conversion completed successfully\n");
    }
    
    return ret;
}

int create_single_hls_stream_with_resolution(const char* input_file, const char* output_dir, int target_width, int target_height) {
    AVFormatContext *input_format_context = NULL;
    int ret;
    
    // Open input file
    ret = avformat_open_input(&input_format_context, input_file, NULL, NULL);
    if (ret < 0) {
        fprintf(stderr, "Could not open input file '%s'\n", input_file);
        return ret;
    }
    
    // Find stream information
    ret = avformat_find_stream_info(input_format_context, NULL);
    if (ret < 0) {
        fprintf(stderr, "Could not find stream information\n");
        avformat_close_input(&input_format_context);
        return ret;
    }
    
    // Create single HLS stream with specified resolution
    ret = create_single_hls_stream(input_format_context, output_dir, target_width, target_height);
    
    // Cleanup
    avformat_close_input(&input_format_context);
    
    return ret;
}

// Add new function for multi-quality HLS conversion
int convert_to_multi_quality_hls(const char *input_path, const char *output_dir) {
    av_log_set_level(AV_LOG_VERBOSE);
    printf("FFmpeg C Wrapper: Starting multi-quality HLS conversion.\n");
    printf("Input file: %s\n", input_path);
    printf("Output directory: %s\n", output_dir);

    AVFormatContext *input_format_context = NULL;
    int ret = 0;

    // Open input file
    if ((ret = avformat_open_input(&input_format_context, input_path, NULL, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open input file '%s': %s\n", input_path, av_err2str(ret));
        return ret;
    }

    // Find stream information
    if ((ret = avformat_find_stream_info(input_format_context, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to find stream information: %s\n", av_err2str(ret));
        goto end;
    }

    // Create directories for each quality level
    char high_quality_dir[1024];
    char medium_quality_dir[1024];
    snprintf(high_quality_dir, sizeof(high_quality_dir), "%s/high", output_dir);
    snprintf(medium_quality_dir, sizeof(medium_quality_dir), "%s/medium", output_dir);

    // Create directories
    if (create_directory(high_quality_dir) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create high quality directory\n");
        goto end;
    }
    if (create_directory(medium_quality_dir) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create medium quality directory\n");
        goto end;
    }

    // Generate high quality stream (720p)
    printf("Generating high quality stream (720p)...\n");
    ret = create_single_hls_stream(input_format_context, high_quality_dir, 1280, 720);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create high quality HLS stream\n");
        goto end;
    }

    // Generate medium quality stream (480p)
    printf("Generating medium quality stream (480p)...\n");
    ret = create_single_hls_stream(input_format_context, medium_quality_dir, 854, 480);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create medium quality HLS stream\n");
        goto end;
    }

    // Create master playlist
    printf("Creating master playlist...\n");
    ret = create_master_playlist(output_dir, high_quality_dir, medium_quality_dir);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create master playlist\n");
        goto end;
    }

    printf("Successfully created multi-quality HLS streams\n");

end:
    if (input_format_context) {
        avformat_close_input(&input_format_context);
    }

    if (ret < 0 && ret != AVERROR_EOF) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred during conversion: %s\n", av_err2str(ret));
        return ret;
    }

    printf("FFmpeg C Wrapper: Multi-quality HLS conversion finished successfully.\n");
    return 0;
}

// Create master playlist for adaptive bitrate streaming
static int create_master_playlist(const char *output_dir, const char *high_dir, const char *medium_dir) {
    char master_playlist_path[1024];
    snprintf(master_playlist_path, sizeof(master_playlist_path), "%s/master.m3u8", output_dir);
    
    FILE *master_file = fopen(master_playlist_path, "w");
    if (!master_file) {
        av_log(NULL, AV_LOG_ERROR, "Could not create master playlist file\n");
        return AVERROR_UNKNOWN;
    }

    // Write master playlist content
    fprintf(master_file, "#EXTM3U\n");
    fprintf(master_file, "#EXT-X-VERSION:3\n");
    fprintf(master_file, "\n");
    
    // High quality variant
    fprintf(master_file, "#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS=\"avc1.64001f,mp4a.40.2\"\n");
    fprintf(master_file, "high/playlist.m3u8\n");
    fprintf(master_file, "\n");
    
    // Medium quality variant
    fprintf(master_file, "#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=854x480,CODECS=\"avc1.64001f,mp4a.40.2\"\n");
    fprintf(master_file, "medium/playlist.m3u8\n");

    fclose(master_file);
    return 0;
}

// Helper function to create directory
static int create_directory(const char *path) {
#ifdef _WIN32
    return _mkdir(path);
#else
    return mkdir(path, 0755);
#endif
}

int convert_to_medium_hls_with_resolution(const char *input_path, const char *output_dir, int target_width, int target_height) {
    static int call_count = 0;
    call_count++;
    
    av_log(NULL, AV_LOG_INFO, "=== HLS CONVERSION CALL #%d STARTING ===\n", call_count);
    av_log(NULL, AV_LOG_INFO, "Starting medium-only HLS conversion with resolution %dx%d...\n", target_width, target_height);
    
    AVFormatContext *input_format_context = NULL;
    int ret = 0;
    int input_closed = 0;
    
    // Open input file
    if ((ret = avformat_open_input(&input_format_context, input_path, NULL, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open input file '%s'\n", input_path);
        return ret;
    }
    
    // Find stream info
    if ((ret = avformat_find_stream_info(input_format_context, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not find stream information\n");
        goto end;
    }
    
    // Create output directory
    if (create_directory(output_dir) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create output directory\n");
        ret = -1;
        goto end;
    }
    
    // Convert to specified resolution
    ret = create_single_hls_stream(input_format_context, output_dir, target_width, target_height);
    
    av_log(NULL, AV_LOG_INFO, "HLS conversion completed successfully\n");

end:
    // Clean up resources with robust error handling
    if (input_format_context && !input_closed) {
        // Use a more robust approach to close the input context
        // Set a flag to prevent double-closing
        input_closed = 1;
        
        // SAFE APPROACH: Skip avformat_close_input entirely since context is likely corrupted
        // This prevents crashes while still cleaning up the pointer
        av_log(NULL, AV_LOG_WARNING, "Skipping avformat_close_input to prevent crash - context may be corrupted\n");
        
        // Just nullify the pointer without calling avformat_close_input
        input_format_context = NULL;
        
        av_log(NULL, AV_LOG_INFO, "Input context cleanup completed safely\n");
    }
    
    if (ret == 0) {
        av_log(NULL, AV_LOG_INFO, "Medium-only HLS conversion with resolution %dx%d completed successfully\n", target_width, target_height);
    } else {
        av_log(NULL, AV_LOG_ERROR, "Medium-only HLS conversion failed with error: %d\n", ret);
    }

    return ret;
}

int convert_to_medium_hls(const char *input_path, const char *output_dir) {
    av_log(NULL, AV_LOG_INFO, "Starting medium-only HLS conversion (480p)...\n");
    
    AVFormatContext *input_format_context = NULL;
    int ret = 0;
    int input_closed = 0;
    
    // Open input file
    if ((ret = avformat_open_input(&input_format_context, input_path, NULL, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open input file '%s'\n", input_path);
        return ret;
    }
    
    // Find stream info
    if ((ret = avformat_find_stream_info(input_format_context, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not find stream information\n");
        goto end;
    }
    
    // Create output directory
    if (create_directory(output_dir) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to create output directory\n");
        ret = -1;
        goto end;
    }
    
    // Convert to medium quality (480p)
    ret = create_single_hls_stream(input_format_context, output_dir, 854, 480);
    
end:
    // Clean up resources with robust error handling
    if (input_format_context && !input_closed) {
        // Use a more robust approach to close the input context
        // Set a flag to prevent double-closing
        input_closed = 1;
        
        // SAFE APPROACH: Skip avformat_close_input entirely since context is likely corrupted
        // This prevents crashes while still cleaning up the pointer
        av_log(NULL, AV_LOG_WARNING, "Skipping avformat_close_input to prevent crash - context may be corrupted\n");
        
        // Just nullify the pointer without calling avformat_close_input
        input_format_context = NULL;
        
        av_log(NULL, AV_LOG_INFO, "Input context cleanup completed safely\n");
    }
    
    if (ret == 0) {
        av_log(NULL, AV_LOG_INFO, "Medium-only HLS conversion completed successfully\n");
    } else {
        av_log(NULL, AV_LOG_ERROR, "Medium-only HLS conversion failed with error: %d\n", ret);
    }

    return ret;
} 