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
#include "libswscale/swscale.h"
#include "libavutil/opt.h"

// Define resolution configurations
typedef struct {
    int width;
    int height;
    int video_bitrate;
    int audio_bitrate;
    const char* name;
} ResolutionConfig;

static const ResolutionConfig resolutions[] = {
    {360, 202, 500000, 96000, "360p"},
    {480, 270, 1000000, 128000, "480p"},
    {720, 405, 2000000, 192000, "720p"}
};

static const int num_resolutions = sizeof(resolutions) / sizeof(ResolutionConfig);

// Forward declaration
static int create_hls_stream(AVFormatContext *input_format_context, const char *output_dir, const ResolutionConfig *config);
static int create_hls_stream_simple(AVFormatContext *input_format_context, const char *output_dir, const ResolutionConfig *config);

int convert_to_hls(const char *input_path, const char *output_dir) {
    // Set log level for detailed output during debugging
    av_log_set_level(AV_LOG_VERBOSE);
    printf("FFmpeg C Wrapper: Starting multi-resolution HLS conversion.\n");
    printf("Input file: %s\n", input_path);
    printf("Output directory: %s\n", output_dir);

    AVFormatContext *input_format_context = NULL;
    int ret = 0;
    int success_count = 0;

    // 1. Open input file and allocate format context
    if ((ret = avformat_open_input(&input_format_context, input_path, NULL, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Could not open input file '%s': %s\n", input_path, av_err2str(ret));
        return ret;
    }

    // 2. Retrieve stream information
    if ((ret = avformat_find_stream_info(input_format_context, NULL)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Failed to find stream information: %s\n", av_err2str(ret));
        goto end;
    }

    av_dump_format(input_format_context, 0, input_path, 0);

    // 3. Create master playlist
    char master_playlist_path[1024];
    snprintf(master_playlist_path, sizeof(master_playlist_path), "%s/playlist.m3u8", output_dir);
    
    FILE *master_playlist = fopen(master_playlist_path, "w");
    if (!master_playlist) {
        av_log(NULL, AV_LOG_ERROR, "Could not create master playlist file\n");
        ret = AVERROR_UNKNOWN;
        goto end;
    }
    
    // Write master playlist header
    fprintf(master_playlist, "#EXTM3U\n");
    fprintf(master_playlist, "#EXT-X-VERSION:3\n");
    
    // 4. Create HLS streams for each resolution using FFmpeg command-line approach
    for (int res_idx = 0; res_idx < num_resolutions; res_idx++) {
        const ResolutionConfig *config = &resolutions[res_idx];
        printf("Processing resolution: %s (%dx%d)\n", config->name, config->width, config->height);
        
        ret = create_hls_stream_simple(input_format_context, output_dir, config);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to create HLS stream for %s\n", config->name);
            // Continue with other resolutions instead of failing completely
            continue;
        }
        
        // Add successful resolution to master playlist
        fprintf(master_playlist, "#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%dx%d\n", 
                config->video_bitrate + config->audio_bitrate,
                config->width, config->height);
        fprintf(master_playlist, "%s.m3u8\n", config->name);
        success_count++;
    }
    
    fclose(master_playlist);

    // Check if at least one resolution was successful
    if (success_count == 0) {
        av_log(NULL, AV_LOG_ERROR, "No HLS streams were created successfully\n");
        ret = AVERROR_UNKNOWN;
        goto end;
    }

    printf("Successfully created %d HLS streams\n", success_count);

end:
    // Clean up resources
    avformat_close_input(&input_format_context);

    if (ret < 0 && ret != AVERROR_EOF) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred during conversion: %s\n", av_err2str(ret));
        return ret;
    }

    printf("FFmpeg C Wrapper: Multi-resolution HLS conversion finished successfully.\n");
    return 0;
}

static int create_hls_stream_simple(AVFormatContext *input_format_context, const char *output_dir, const ResolutionConfig *config) {
    AVFormatContext *output_format_context = NULL;
    int ret;
    int *stream_mapping = NULL;

    // Create output playlist path for this resolution
    char output_playlist[1024];
    snprintf(output_playlist, sizeof(output_playlist), "%s/%s.m3u8", output_dir, config->name);

    // Allocate output context for HLS
    avformat_alloc_output_context2(&output_format_context, NULL, "hls", output_playlist);
    if (!output_format_context) {
        av_log(NULL, AV_LOG_ERROR, "Could not create HLS output context for %s\n", config->name);
        return AVERROR_UNKNOWN;
    }

    // Copy streams from input to output
    int stream_index = 0;
    
    if (input_format_context->nb_streams > 0) {
        stream_mapping = av_calloc(input_format_context->nb_streams, sizeof(int));
        if (!stream_mapping) {
            av_log(NULL, AV_LOG_ERROR, "Failed to allocate stream mapping array\n");
            ret = AVERROR(ENOMEM);
            goto end;
        }
        
        // Initialize all entries to -1 (unused)
        for (int i = 0; i < input_format_context->nb_streams; i++) {
            stream_mapping[i] = -1;
        }
        
        // Process streams
        for (int i = 0; i < input_format_context->nb_streams; i++) {
            AVStream *out_stream;
            AVStream *in_stream = input_format_context->streams[i];
            const AVCodecParameters *in_codecpar = in_stream->codecpar;

            if (in_codecpar->codec_type != AVMEDIA_TYPE_AUDIO &&
                in_codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
                continue;
            }

            stream_mapping[i] = stream_index++;
            out_stream = avformat_new_stream(output_format_context, NULL);
            if (!out_stream) {
                av_log(NULL, AV_LOG_ERROR, "Failed allocating output stream\n");
                ret = AVERROR_UNKNOWN;
                goto end;
            }
            
            // Copy codec parameters
            ret = avcodec_parameters_copy(out_stream->codecpar, in_codecpar);
            if (ret < 0) {
                av_log(NULL, AV_LOG_ERROR, "Failed to copy codec parameters: %s\n", av_err2str(ret));
                goto end;
            }
            
            // For video streams, set the target resolution and bitrate
            if (in_codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                out_stream->codecpar->width = config->width;
                out_stream->codecpar->height = config->height;
                out_stream->codecpar->bit_rate = config->video_bitrate;
            }
            
            // For audio streams, set the target bitrate
            if (in_codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                out_stream->codecpar->bit_rate = config->audio_bitrate;
            }
            
            out_stream->codecpar->codec_tag = 0;
        }
    }
    
    av_dump_format(output_format_context, 0, output_playlist, 1);

    // Open the output file for writing
    if (!(output_format_context->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&output_format_context->pb, output_playlist, AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not open output file '%s': %s\n", output_playlist, av_err2str(ret));
            goto end;
        }
    }

    // Set HLS options
    AVDictionary *hls_options = NULL;
    char segment_filename[1024];
    snprintf(segment_filename, sizeof(segment_filename), "%s/%s_segment%%03d.ts", output_dir, config->name);
    
    av_dict_set(&hls_options, "hls_time", "6", 0);
    av_dict_set(&hls_options, "hls_list_size", "0", 0);
    av_dict_set(&hls_options, "hls_segment_filename", segment_filename, 0);

    // Write the stream header
    ret = avformat_write_header(output_format_context, &hls_options);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred when writing header to output file: %s\n", av_err2str(ret));
        goto end;
    }
    av_dict_free(&hls_options);

    // Copy packets from input to output
    AVPacket pkt;
    while (1) {
        ret = av_read_frame(input_format_context, &pkt);
        if (ret < 0) {
            break; // EOF or error
        }

        // Skip packets if we have no stream mapping or if this stream is not mapped
        if (!stream_mapping || pkt.stream_index >= input_format_context->nb_streams || 
            stream_mapping[pkt.stream_index] < 0) {
            av_packet_unref(&pkt);
            continue;
        }

        AVStream *in_stream = input_format_context->streams[pkt.stream_index];
        pkt.stream_index = stream_mapping[pkt.stream_index];
        AVStream *out_stream = output_format_context->streams[pkt.stream_index];

        // Rescale PTS/DTS
        av_packet_rescale_ts(&pkt, in_stream->time_base, out_stream->time_base);
        pkt.pos = -1;

        // Write the packet
        ret = av_interleaved_write_frame(output_format_context, &pkt);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Error muxing packet: %s\n", av_err2str(ret));
            break;
        }
        av_packet_unref(&pkt);
    }

    // Write the stream trailer
    av_write_trailer(output_format_context);

end:
    // Clean up resources
    if (output_format_context && !(output_format_context->oformat->flags & AVFMT_NOFILE)) {
        avio_closep(&output_format_context->pb);
    }
    avformat_free_context(output_format_context);
    if (stream_mapping) {
        av_free(stream_mapping);
    }

    return ret;
} 