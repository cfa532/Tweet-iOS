#ifndef FFmpegWrapper_h
#define FFmpegWrapper_h

#include <stdio.h>

/**
 * Converts a video file to an HLS stream using FFmpeg.
 *
 * This function takes an input video file and converts it into a series of
 * MPEG-2 Transport Stream (.ts) files and an M3U8 playlist.
 *
 * @param input_path The absolute path to the input video file.
 * @param output_dir The absolute path to the directory where the HLS files (.ts and .m3u8) will be saved.
 * @return Returns 0 on success, and a non-zero value on failure.
 */
int convert_to_hls(const char *input_path, const char *output_dir);

/**
 * Converts a video file to multiple quality HLS streams with adaptive bitrate.
 *
 * This function creates both high quality (720p) and medium quality (480p) HLS streams
 * along with a master playlist that enables adaptive bitrate streaming.
 *
 * @param input_path The absolute path to the input video file.
 * @param output_dir The absolute path to the directory where the HLS files will be saved.
 * @return Returns 0 on success, and a non-zero value on failure.
 */
int convert_to_multi_quality_hls(const char *input_path, const char *output_dir);

// Function to create a single HLS stream with transcoding
int create_single_hls_stream_with_resolution(const char* input_file, const char* output_dir, int target_width, int target_height);

// HLS conversion functions
int convert_to_medium_hls(const char *input_path, const char *output_dir);
int convert_to_medium_hls_with_resolution(const char *input_path, const char *output_dir, int target_width, int target_height);

#endif /* FFmpegWrapper_h */ 