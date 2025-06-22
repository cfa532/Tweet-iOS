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


int convert_to_hls(const char *input_path, const char *output_dir) {
    // Set log level for detailed output during debugging
    av_log_set_level(AV_LOG_VERBOSE);
    printf("FFmpeg C Wrapper: Starting HLS conversion.\n");
    printf("Input file: %s\n", input_path);
    printf("Output directory: %s\n", output_dir);

    AVFormatContext *input_format_context = NULL;
    AVFormatContext *output_format_context = NULL;
    int ret;

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

    // 3. Prepare output context for HLS
    char output_playlist[1024];
    snprintf(output_playlist, sizeof(output_playlist), "%s/playlist.m3u8", output_dir);

    avformat_alloc_output_context2(&output_format_context, NULL, "hls", output_playlist);
    if (!output_format_context) {
        av_log(NULL, AV_LOG_ERROR, "Could not create HLS output context\n");
        ret = AVERROR_UNKNOWN;
        goto end;
    }

    // 4. Copy streams from input to output (Remuxing)
    int *stream_mapping = av_calloc(input_format_context->nb_streams, sizeof(int));
    if (!stream_mapping) {
        ret = AVERROR(ENOMEM);
        goto end;
    }
    int stream_index = 0;

    for (int i = 0; i < input_format_context->nb_streams; i++) {
        AVStream *out_stream;
        AVStream *in_stream = input_format_context->streams[i];
        const AVCodecParameters *in_codecpar = in_stream->codecpar;

        if (in_codecpar->codec_type != AVMEDIA_TYPE_AUDIO &&
            in_codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
            stream_mapping[i] = -1;
            continue;
        }

        stream_mapping[i] = stream_index++;
        out_stream = avformat_new_stream(output_format_context, NULL);
        if (!out_stream) {
            av_log(NULL, AV_LOG_ERROR, "Failed allocating output stream\n");
            ret = AVERROR_UNKNOWN;
            goto end;
        }
        ret = avcodec_parameters_copy(out_stream->codecpar, in_codecpar);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Failed to copy codec parameters: %s\n", av_err2str(ret));
            goto end;
        }
        out_stream->codecpar->codec_tag = 0;
    }
    
    av_dump_format(output_format_context, 0, output_playlist, 1);

    // 5. Open the output file for writing
    if (!(output_format_context->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&output_format_context->pb, output_playlist, AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_log(NULL, AV_LOG_ERROR, "Could not open output file '%s': %s\n", output_playlist, av_err2str(ret));
            goto end;
        }
    }

    // 6. Set HLS options
    AVDictionary *hls_options = NULL;
    char segment_filename[1024];
    snprintf(segment_filename, sizeof(segment_filename), "%s/segment%%03d.ts", output_dir);
    
    av_dict_set(&hls_options, "hls_time", "6", 0);
    av_dict_set(&hls_options, "hls_list_size", "0", 0); // Keep all segments in the playlist
    av_dict_set(&hls_options, "hls_segment_filename", segment_filename, 0);

    // 7. Write the stream header
    ret = avformat_write_header(output_format_context, &hls_options);
    if (ret < 0) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred when writing header to output file: %s\n", av_err2str(ret));
        goto end;
    }
    av_dict_free(&hls_options);

    // 8. Copy packets from input to output
    AVPacket pkt;
    while (1) {
        ret = av_read_frame(input_format_context, &pkt);
        if (ret < 0) {
            break; // EOF or error
        }

        if (stream_mapping[pkt.stream_index] < 0) {
            av_packet_unref(&pkt);
            continue;
        }

        AVStream *in_stream  = input_format_context->streams[pkt.stream_index];
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

    // 9. Write the stream trailer
    av_write_trailer(output_format_context);

end:
    // 10. Clean up resources
    avformat_close_input(&input_format_context);
    if (output_format_context && !(output_format_context->oformat->flags & AVFMT_NOFILE)) {
        avio_closep(&output_format_context->pb);
    }
    avformat_free_context(output_format_context);
    av_free(stream_mapping);

    if (ret < 0 && ret != AVERROR_EOF) {
        av_log(NULL, AV_LOG_ERROR, "Error occurred during conversion: %s\n", av_err2str(ret));
        return ret;
    }

    printf("FFmpeg C Wrapper: HLS conversion finished successfully.\n");
    return 0;
} 