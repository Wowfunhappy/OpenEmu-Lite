# PICO-8 Audio Engine - Reverse-Engineered Reference

Decompiled from the PICO-8 web player (Emscripten asm.js build).  
This document describes the **real** PICO-8 audio DSP pipeline at sample level.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Memory Layout](#memory-layout)
3. [Function: Fq - Main Mixer](#fq---main-mixer)
4. [Function: Gq - Per-Channel Driver](#gq---per-channel-driver)
5. [Function: Hq - Sample Generator / Tick Driver](#hq---sample-generator--tick-driver)
6. [Function: Iq - Core Synthesizer (per-tick)](#iq---core-synthesizer)
7. [Function: Kq - Effect & State Update](#kq---effect--state-update)
8. [Function: Mq - Envelope / SFX Note Decoder](#mq---envelope--sfx-note-decoder)
9. [Function: Jq - Waveform Renderer](#jq---waveform-renderer)
10. [Function: Lq - Duration Calculation](#lq---duration-calculation)
11. [Function: pp - PRNG](#pp---prng)
12. [Differences from fake-08](#differences-from-fake-08)

---

## Architecture Overview

PICO-8's audio runs at **22050 Hz** internally. The pipeline is:

```
Fq (Main Mixer)
 |-- for each of 16 channels:
 |    Gq (Per-Channel Driver)
 |     |-- Hq (Sample Generator)
 |     |    |-- per tick (183 samples):
 |     |    |    Iq (Core Synthesizer)
 |     |    |     |-- Kq (Effect/state update: pitch, volume, effects)
 |     |    |     |    |-- Mq (Envelope: reads SFX note data, applies effects)
 |     |    |     |-- Jq (Waveform render: generates 183 samples)
 |     |    |     |-- Crossfade between old and new state (64 samples)
 |     |    |     |-- Low-pass filter (dampen)
 |     |    |-- SFX overlay (Gq handles overlaying from another SFX buffer)
 |-- Hierarchical pair-wise mixing with soft clipping
 |-- Master volume
 |-- Optional reverb bus mix
 |-- Sample rate / channel count conversion for output
```

Key constants:
- **22050 Hz** internal sample rate
- **183 samples per tick** (per speed unit per note)
- **16 channels** (4 normal + 4 doubled + 8 for half-rate mode expansion)
- **32 notes per SFX**
- **64 SFX slots**, **64 music patterns**
- Waveform phase uses **16-bit unsigned** wrapping (0-65535)

---

## Memory Layout

### Channel Struct (13552 bytes per channel)

16 channels starting at address `2711096`, spaced `13552` bytes apart.

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 - 8219 | 8220 | | (padding / unused at start) |
| 8220 | 4 | `music_data_ptr` | Pointer to the global music/SFX data block |
| 8224 | 4 | `sfx_ptr` | Pointer to current SFX definition (into music_data+16+sfx*680), or 0 |
| 8228 | 4 | `tick` | Current tick counter (incremented each 183-sample frame) |
| 8232 | 4 | `total_samples` | Total samples generated since SFX start |
| 8236 | 4 | `can_loop` | Whether looping is enabled |
| 8240 | 4 | `channel_index` | This channel's index (0-3 for normal) |
| 8244 | 366 | `output_buf[183]` | Current tick's rendered samples (int16) |
| 8610 | 2928 | `reverb_ring[8][183]` | Ring buffer of last 8 ticks of output (8 * 366 bytes) |
| 11538 | 2 | | (padding) |
| 11540 | 4 | `reverb_write_idx` | Write index into reverb ring buffer (mod 8) |
| 11544 | 2 | `crossfade_pos` | Position within output_buf for crossfade reads |
| 11546 | 2 | | (padding) |
| 11548 | 4 | `is_music` | Whether this channel is playing music (vs sfx()) |
| 11552 | 4 | `music_pattern_idx` | Current music pattern index |
| 11556 | 352 | `synth_state` | Current synthesizer state (see below) |
| 11908 | 4 | `prev_key` | Previous note's key (for slide effect) |
| 11912 | 4 | `prev_instrument` | Previous note's instrument |
| 11916 | 4 | `prev_volume` | Previous note's volume (scaled) |
| 11920 | 8 | | (more prev state for Mq) |
| 11928 | 4 | `prev_mq_key` | Previous Mq key (for slide within custom SFX) |
| 11932 | 4 | `prev_mq_instr` | Previous Mq instrument |
| 11936 | 4 | `prev_mq_vol` | Previous Mq volume |
| ... | | | |
| 11988 | 4 | `envelope_tick` | Envelope position counter (ticks into SFX) |
| 11992 | 4 | `hw_reverb_level` | Hardware-forced reverb level |
| 11996 | 4 | `dampen_level` | Dampen/low-pass filter level (0, 8, 12, 15) |
| 12000 | 4 | `duration` | Remaining duration in ticks |
| 12004 | 4 | `debug_entry_count` | Debug info entry count |
| 12008 | 4 | `timing_prev` | Previous timing value |
| 12012 | 4 | `timing_current` | Current timing estimate |
| 12016 | 1536 | `debug_info[64]` | Debug entries (24 bytes each) |

### Synth State Struct (352 bytes, at channel+11556)

This is the state passed between Kq (effect update) and Jq (waveform render).

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 4 | `instrument` | Waveform type (0-7 built-in, 8 = custom) |
| 4 | 4 | `phase_primary` | Primary oscillator phase (0-65535, wraps) |
| 8 | 4 | `phase_inc_primary` | Primary phase increment per sample |
| 12 | 4 | `phase_secondary` | Secondary oscillator phase (for detune, 0-131071) |
| 16 | 4 | `phase_inc_secondary` | Secondary phase increment |
| 20 | 4 | `noise_sample` | Noise generator: current filtered sample |
| 24 | 4 | `noise_flipflop` | Noise generator: alternating flag |
| 28 | 4 | `note_volume` | Volume after effects (in 8.8 fixed point, 0-1792 range) |
| 32 | 4 | `note_pitch` | Pitch after effects (16.16 fixed point, key << 16) |
| 36 | 4 | `base_key` | Base key from SFX note data |
| 40 | 4 | `envelope_volume` | Volume scaled by envelope / vibrato depth |
| 44 | 4 | `noise_counter` | Noise: period counter for sample-and-hold |
| 48 | 4 | `noise_prev_sample` | Noise: previous random sample |
| 52 | 4 | `noise_cur_sample` | Noise: current random sample |
| 56 | 4 | `raw_volume` | Raw volume from SFX note (0-7) |
| 60 | 4 | `raw_key` | Raw key from SFX note (0-63) |
| 64 | 4 | `raw_instrument` | Raw instrument from SFX note |
| 68 | 4 | `effect_type` | Current effect (0-7, set by Mq) |
| 72 | 4 | `effect_flags` | Effect flags from SFX definition |
| 76 | 4 | `drop_factor` | Fade factor for drop effect (0-256) |
| 80 | 4 | `detune_mode` | Detune level: 0=none, 1=slight, 2=heavy (from filters bits) |
| 84 | 4 | `buzz_flag` | Buzz/harmonics flag (from filters bits) |
| 88 | 4 | `custom_or_noise_flag` | Custom instrument / noise modifier flag |
| 92 | 4 | `dampen_level` | Per-note dampen level |
| 96 | 256 | `custom_waveform[64]` | Custom waveform data (64 x int32, signed 8-bit values << 7) |

### SFX Data Block (at music_data_ptr)

| Offset | Size | Description |
|--------|------|-------------|
| 0 | 16 | Header / global flags |
| 16 | 43520 | 64 SFX definitions, 680 bytes each |
| 43536 | 1024 | 64 pattern channel maps, 16 bytes each (4 x int32) |
| 44560 | 256 | 64 music flags, 4 bytes each |

### SFX Definition (680 bytes)

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 4 | `flags` | Filter/effect flags byte (detune, buzz, reverb, dampen bits) |
| 4 | 4 | | (reserved) |
| 8 | 4 | `speed` | Playback speed (1-255, ticks per note) |
| 12 | 4 | `loop_start` | Loop range start note index |
| 16 | 4 | `loop_end` | Loop range end note index |
| 20 | 640 | `notes[32]` | 32 notes, each 20 bytes |

### Note (20 bytes)

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 4 | `key` | Pitch (0-63, C-0 to D#-5) |
| 4 | 4 | `instrument` | Waveform (0-7 built-in, or SFX index for custom) |
| 8 | 4 | `volume` | Volume (0-7) |
| 12 | 4 | `effect` | Effect type (0-7) |
| 16 | 4 | `custom` | Custom instrument flag (0 or 1) |

---

## Fq - Main Mixer

**Signature:** `Fq(audio_ctx, output_buffer, buffer_size)`

Mixes all 16 channels into the final output buffer.

```c
void Fq(int audio_ctx, int16_t* output, int buffer_size) {
    global_buffer_size = buffer_size;
    
    if (audio_locked()) {
        memset(output, 0, buffer_size);
        return;
    }
    
    frame_counter++;
    if (frame_counter < 3 && audio_initialized) {
        memset(output, 0, buffer_size);
        return;
    }
    
    // Determine actual sample count based on output format
    int raw_frames = buffer_size / (output_channels == 0 ? 1 : output_channels * 2);
    int num_samples = (sample_rate == 44100) ? raw_frames / 2 : raw_frames;
    
    // Timing check - skip if > 500ms since last call (tab was backgrounded etc.)
    if (last_timestamp != -1) {
        if ((current_time() - last_timestamp) > 500) {
            last_timestamp = current_time();
            if (num_samples > 0)
                memset(output, 0, num_samples * 2);
            return;
        }
    } else {
        last_timestamp = current_time();
    }
    
    // Reset "any notes changed" flag
    notes_changed = 0;
    
    // Generate audio for all 16 channels
    // Channels are at fixed addresses, 13552 bytes apart
    Gq(channel[0],  num_samples);  // 2711096
    Gq(channel[1],  num_samples);  // 2724648
    Gq(channel[2],  num_samples);  // 2738200
    Gq(channel[3],  num_samples);  // 2751752
    Gq(channel[4],  num_samples);  // 2765304 (half-rate shadows)
    Gq(channel[5],  num_samples);  // 2778856
    Gq(channel[6],  num_samples);  // 2792408
    Gq(channel[7],  num_samples);  // 2805960
    Gq(channel[8],  num_samples);  // 2819512
    Gq(channel[9],  num_samples);  // 2833064
    Gq(channel[10], num_samples);  // 2846616
    Gq(channel[11], num_samples);  // 2860168
    Gq(channel[12], num_samples);  // 2873720
    Gq(channel[13], num_samples);  // 2887272
    Gq(channel[14], num_samples);  // 2900824
    Gq(channel[15], num_samples);  // 2914376
    
    if (notes_changed)
        stat25_counter++;
    
    // Mute channels 4-7 if in standard 4-channel mode and they have overlays
    if (extended_audio_mode) {
        if (chan4_overlay) memset(channel[4], 0, buffer_size);
        if (chan5_overlay) memset(channel[5], 0, buffer_size);
        if (chan6_overlay) memset(channel[6], 0, buffer_size);
        if (chan7_overlay) memset(channel[7], 0, buffer_size);
    }
    
    // --- Hierarchical pair-wise mixing with soft clipping ---
    // Mix pairs: (0,1), (2,3), (4,5), ... up to num_active_channels
    // Then pairs of pairs, etc. This is a butterfly reduction.
    int stride = 2;
    do {
        int half = stride / 2;
        for (int base = 0; base < num_active_channels; base += stride) {
            int partner = base + half;
            for (int s = 0; s < num_samples; s++) {
                int mixed = channel[base].samples[s] + channel[partner].samples[s];
                // Soft clipping: if |mixed| > 24575, compress the excess by /5
                if (mixed > 24575)
                    mixed = (mixed - 24576) / 5 + 24576;
                else if (mixed < -24575)
                    mixed = (mixed + 24576) / 5 - 24576;
                channel[base].samples[s] = mixed;
            }
        }
        stride <<= 1;
    } while (stride <= num_active_channels);
    
    // --- Master volume ---
    int master_vol = master_volume;  // 0-256, 256 = unity
    if (master_vol != 256 && num_samples > 0) {
        for (int s = 0; s < num_samples; s++) {
            channel[0].samples[s] = (master_vol * channel[0].samples[s]) >> 8;
        }
    }
    
    // --- Optional reverb bus (PCM / stat36 audio) ---
    if (pcm_enabled && pcm_active) {
        int pcm_vol = (pcm_volume * pcm_mix_level) >> 16;
        if (pcm_vol) {
            // Scale PCM buffer by volume
            for (int s = 0; s < num_samples; s++)
                pcm_buffer[s] = (pcm_vol * pcm_buffer[s]) >> 8;
            // Mix PCM into channel 0 with soft clipping
            for (int s = 0; s < num_samples; s++) {
                int mixed = pcm_buffer[s] + channel[0].samples[s];
                if (mixed > 24575)
                    mixed = (mixed - 24576) / 5 + 24576;
                else if (mixed < -24575)
                    mixed = (mixed + 24576) / 5 - 24576;
                channel[0].samples[s] = mixed;
            }
        }
    }
    
    // --- Output format conversion ---
    if (sample_rate == 22050 && output_channels == 1) {
        // Direct copy, 1:1
        for (int s = 0; s < num_samples; s++)
            output[s] = channel[0].samples[s];
    } else if (sample_rate == 44100 && output_channels == 2) {
        // Upsample 2x and duplicate to stereo (4x expansion)
        for (int s = 0; s < num_samples * 4; s++)
            output[s] = channel[0].samples[s / 4];
    }
    
    // Optional audio callback
    if (audio_callback)
        audio_callback(output, buffer_size / 2);
    
    // Optional WAV recording
    if (recording_enabled && wav_writer) {
        /* writes samples to WAV file */
    }
}
```

---

## Gq - Per-Channel Driver

**Signature:** `Gq(channel, num_samples)`

Handles half-rate doubling and SFX overlay mixing for a single channel.

```c
void Gq(Channel* chan, int num_samples) {
    // Clear output buffer
    memset(chan->samples, 0, 8192);  // clear first 4096 int16 samples
    
    // Check if this channel needs half-rate (double each sample)
    int hw_half_rate = hw_half_rate_flags;
    int chan_bit = 1 << (chan->channel_index + 4);
    
    if (chan_bit & hw_half_rate) {
        // Generate at half the sample count, then double
        Hq(chan, (num_samples / 2) + 1);
        // Duplicate: stretch samples by 2x (work backwards to avoid overwrite)
        for (int i = num_samples; i > 0; i--)
            chan->samples[i-1] = chan->samples[(i-1) / 2];
    } else {
        Hq(chan, num_samples);
    }
    
    // --- SFX Overlay ---
    // If there's an overlay SFX (from sfx() call over music), mix it in
    SfxOverlay* overlay = chan->overlay_ptr;  // at chan+8208
    if (!overlay || num_samples <= 0)
        return;
    
    int overlay_length = overlay->length;
    int overlay_pos = chan->overlay_pos;     // at chan+8216
    int overlay_loop = overlay->loop_flag;   // at +28
    int16_t* overlay_data = overlay->data;   // at +20
    
    int remaining = num_samples;
    while (remaining > 0) {
        int avail_output = num_samples - (num_samples - remaining);
        int avail_overlay = overlay_length - overlay_pos;
        int count = min(avail_output, avail_overlay);
        if (count < 1) break;
        
        // Copy overlay samples over channel output
        for (int i = 0; i < count; i++)
            chan->samples[write_pos + i] = overlay_data[overlay_pos + i];
        
        overlay_pos += count;
        write_pos += count;
        
        // Handle looping
        if (!overlay_loop || overlay_pos < overlay_length)
            chan->overlay_pos = overlay_pos;
        else
            chan->overlay_pos = 0;  // loop back to start
        
        if (write_pos >= num_samples) break;
    }
    
    // If overlay has finished (pos >= length and no loop)
    if (overlay_pos >= overlay_length) {
        chan->is_music = 0;
        chan->overlay_ptr = 0;
        chan->can_loop = 0;
        chan->total_samples = 0;
        chan->music_data_ptr = 0;
        // (also clears the next 4 bytes)
    }
}
```

---

## Hq - Sample Generator / Tick Driver

**Signature:** `Hq(channel, num_samples)`

The main per-channel loop. Runs Iq once per tick (183 samples), managing crossfade,
reverb ring buffer, dampen filter, and hardware distortion.

```c
void Hq(Channel* chan, int num_samples) {
    // Update timing estimate (smoothed)
    chan->timing_prev = chan->timing_current;
    int sample_time_ms = (num_samples * 2 / (output_channels == 0 ? 1 : output_channels * 2)) 
                         * 1000 / sample_rate;
    int now = get_time_ms();
    int smoothed = ((chan->timing_current + sample_time_ms) * 6 + now * 2) / 8;
    chan->timing_current = max(smoothed, now - 200);
    
    chan->debug_entry_count = 0;
    memset(chan->debug_info, 0, 1536);  // Clear 64 debug entries
    
    if (num_samples <= 0) return;
    
    int16_t* output = chan->samples;  // at offset 0 in channel
    int remaining = num_samples;
    
    while (remaining > 0) {
        // --- Fill from existing output buffer (crossfade residual) ---
        int crossfade_pos = chan->crossfade_pos;  // at +11544, int16
        if (crossfade_pos < 183) {
            int copyable = 183 - crossfade_pos;
            int count = min(copyable, remaining);
            memcpy(output, &chan->output_buf[crossfade_pos], count * 2);
            chan->crossfade_pos += count;
            remaining -= count;
            output += count;
        }
        
        // --- Record debug info ---
        int entry = chan->debug_entry_count;
        if (entry < 64) {
            chan->debug_info[entry].tick = chan->tick;
            chan->debug_info[entry].total_samples = chan->total_samples;
            chan->debug_info[entry].sfx_ptr = chan->sfx_ptr;
            chan->debug_info[entry].note_index = 0;
            if (chan->sfx_ptr) {
                int speed = chan->sfx_ptr->speed;
                speed = max(speed, 1);
                chan->debug_info[entry].note_index = chan->tick / speed;
            }
            chan->debug_info[entry].pattern_idx = chan->music_pattern_idx;
            chan->debug_info[entry].stat25 = stat25_counter;
            chan->debug_entry_count = entry + 1;
        }
        
        if (remaining <= 0) break;
        
        // --- Compute reverb/dampen levels ---
        int16_t prev_last_sample = chan->output_buf[182];  // last sample before overwrite
        
        int sfx_ptr = chan->sfx_ptr;
        int sfx_flags = sfx_ptr ? (sfx_ptr->flags >> 3) / 3 % 3 : 0;  // reverb from SFX
        int chan_flags = (chan->state_at_11628 >> 3);
        int reverb_sfx = (sfx_flags / 1) % 3;
        int reverb_chan = (chan_flags / 1) % 3;
        int reverb_level = max(reverb_sfx, reverb_chan);
        
        int hw_reverb = hw_reverb_flags;
        int chan_idx = chan->channel_index;
        int chan_mask_hi = 1 << (chan_idx + 4);
        int chan_mask_lo = 1 << chan_idx;
        
        // Hardware can force reverb
        chan->hw_reverb_level = 
            (chan_mask_lo & hw_reverb) ? 2 :
            ((chan_mask_hi & hw_reverb) ? max(reverb_level, 1) : reverb_level);
        
        // Compute dampen level from SFX and hardware flags
        int damp_sfx = sfx_ptr ? (sfx_ptr->flags >> 3) / 9 % 3 : 0;
        int damp_chan = (chan_flags / 3) % 3;  // simplified
        int damp = max(damp_sfx, damp_chan);
        int damp_level = (damp == 2) ? 12 : (damp == 1) ? 8 : 0;
        
        int hw_lowpass = hw_lowpass_flags;
        if (hw_lowpass & chan_mask_hi) damp_level = max(damp_level, 8);
        if (hw_lowpass & chan_mask_lo) damp_level = max(damp_level, 12);
        int combined = 17 << chan_idx;
        if ((hw_lowpass & combined) == combined)
            damp_level = max(damp_level, 15);
        chan->dampen_level = damp_level;
        
        // --- Run synthesizer for one tick (183 samples) ---
        Iq(chan, chan->output_buf);
        
        // --- Hardware distortion ---
        int hw_distort = hw_distort_flags;
        if (chan_mask_lo & hw_distort) {
            // Heavy distort: quantize to 12-bit steps
            for (int s = 0; s < 183; s++) {
                int v = chan->output_buf[s];
                chan->output_buf[s] = (v >= 0) ? (v & ~0xFFF) : -((-v) & ~0xFFF);
            }
        } else if (chan_mask_hi & hw_distort) {
            // Light distort: quantize with asymmetric rounding
            for (int s = 0; s < 183; s++) {
                int v = chan->output_buf[s];
                chan->output_buf[s] = v & ~0xFF8;  // mask out low 3 bits of each nibble
            }
        }
        
        // --- Dampen (low-pass IIR filter) ---
        // Applied as: output[n] = (prev * damp + output[n] * (16 - damp)) / 16
        if (damp_level > 0) {
            int weight = 16 - damp_level;
            int16_t prev = prev_last_sample;
            // First sample blends with previous tick's last sample
            int filtered = (damp_level * (int)prev + weight * (int)chan->output_buf[0]) / 16;
            chan->output_buf[0] = filtered;
            int running = filtered;
            for (int s = 1; s < 183; s++) {
                running = (damp_level * running + weight * (int)chan->output_buf[s]) / 16;
                chan->output_buf[s] = running;
            }
        }
        
        // --- Reset crossfade position ---
        chan->crossfade_pos = 0;
        
        // --- Store into reverb ring buffer ---
        int ring_slot = chan->reverb_write_idx % 8;
        memcpy(&chan->reverb_ring[ring_slot], chan->output_buf, 366);
        chan->reverb_write_idx = (chan->reverb_write_idx + 1) % 8;
        
        if (remaining > 0) {
            // Loop back to copy from output_buf
            continue;
        }
    }
    
    // Store final debug entry if space
    if (chan->debug_entry_count < 64) {
        /* same debug recording as above */
    }
}
```

---

## Iq - Core Synthesizer

**Signature:** `Iq(channel, output_buf_366_bytes)`

Called once per tick. Manages note transitions, calls Kq + Jq, and handles
the 64-sample crossfade between the old note and new note.

```c
void Iq(Channel* chan, int16_t output[183]) {
    int16_t temp_state[176];  // stack-allocated copy of previous synth state (352 bytes)
    
    memset(output, 0, 366);  // Clear 183 samples
    
    SfxDef* sfx = chan->sfx_ptr;
    bool has_sfx = (sfx != NULL);
    
    if (has_sfx) {
        int speed = sfx->speed;
        speed = max(speed, 1);
        int tick = chan->tick;
        int note_index = (tick + 1) / speed;
        
        // Save previous synth state for crossfade
        memcpy(temp_state, &chan->synth_state, 352);
        
        // At note boundaries, save previous note info for slide effect
        if ((tick % speed) == 0) {
            chan->prev_instrument = chan->synth_state.raw_instrument;  // +11912 <- +11620
            chan->prev_key       = chan->synth_state.raw_key;          // +11908 <- +11616
            chan->prev_volume    = chan->synth_state.raw_volume;       // +11916 <- +11612
        }
        
        // --- Update synth state for new tick ---
        Kq(chan, &chan->synth_state);
        
        // --- Render 183 samples with new state ---
        Jq(&chan->synth_state, output, 183, chan);
        
        // --- Crossfade: blend first 64 samples with previous state ---
        int16_t old_samples[64];
        memset(&scratch_buffer, 0, 128);  // 64 * 2 bytes (uses global at 1726432)
        Jq(temp_state, old_samples, 64, chan);
        
        for (int i = 0; i < 64; i++) {
            // Linear crossfade: old * (64-i)/64 + new * i/64
            output[i] = (old_samples[i] * (64 - i) + output[i] * i) / 64;
        }
        
        chan->envelope_tick++;
    } else {
        // No SFX playing
        memset(output, 0, 366);
        int next_tick = chan->tick + 1;
        
        // Fade out: if there's residual state, render 64 samples and fade out
        if (chan->synth_state.phase_inc_primary != 0 && 
            chan->synth_state.instrument != 0) {  // simplified condition
            Jq(&chan->synth_state, output, 64, chan);
            for (int i = 0; i < 64; i++)
                output[i] = output[i] * (64 - i) / 64;
        }
        
        // Clear synth state
        chan->synth_state.instrument = 0;
        chan->envelope_tick = 0;
    }
    
    // --- Advance tick counter ---
    chan->tick++;
    chan->duration--;
    chan->envelope_tick++;
    chan->total_samples++;
    
    // --- Handle SFX looping ---
    // If looping is enabled and sfx has valid loop points, wrap tick
    if (has_sfx && chan->can_loop) {
        int loop_start = sfx->loop_start;    // sfx+12
        int loop_end = sfx->loop_end;        // sfx+16
        if (!(loop_start & 128)) {  // bit 7 clear = looping enabled
            if (loop_end > loop_start) {
                int speed = max(sfx->speed, 1);
                if (chan->tick >= loop_end * speed) {
                    chan->tick = loop_start * speed;
                }
            }
        }
    }
    
    // --- Check for SFX end ---
    if (sfx != NULL && chan->is_music == 0) {
        if (chan->duration <= 0) {
            chan->sfx_ptr = NULL;
            // fall through to music pattern check
        } else {
            // Check if remaining notes have any volume
            int loop_flags = sfx->loop_start;
            int loop_end_flags;
            if (!(loop_flags & 128)) {
                int loop_end = sfx->loop_end;
                if (loop_end > loop_flags) {
                    // has loop, keep playing
                } else {
                    // compute effective end
                    int effective_end = (loop_flags > 0 && loop_end == 0) ? loop_flags : 32;
                    // ... duration logic
                }
            }
            // Check for silence in remaining notes (optimization)
            // If all remaining notes have volume 0 and no custom flags, stop early
        }
    }
    
    // --- Music pattern advance ---
    // If music data exists and this is a music channel, check for pattern end
    MusicData* music = chan->music_data_ptr;
    if (!music) return;
    if (chan->duration > 0 || chan->is_music == 0) return;
    
    // Advance to next pattern entry
    int pat_idx = chan->music_pattern_idx;
    if (pat_idx >= 64) return;
    
    notes_changed = 1;
    int flags = music->pattern_flags[pat_idx];
    
    if (flags & 4) {
        // Stop flag: end music
    } else if (flags & 2) {
        // Loop-back flag: find loop start
        if (pat_idx > 0) {
            if (!(flags & 1)) {
                // Search backwards for loop start marker
                while (pat_idx > 0) {
                    pat_idx--;
                    if (music->pattern_flags[pat_idx] & 1) break;
                }
            }
        }
        stat24_pattern = pat_idx;
    } else {
        // Advance to next pattern
        pat_idx++;
        stat24_pattern = pat_idx;
    }
    
    if (pat_idx > 63) {
        // Past end, stop music
        chan->is_music = 0;
        chan->overlay_ptr = 0;
        chan->can_loop = 0;
        chan->total_samples = 0;
        chan->music_data_ptr = 0;
        return;
    }
    
    // Load pattern channel assignments
    int* pattern_chans = &music->patterns[pat_idx];
    // If all 4 channels in this pattern have sfx index > 63, stop
    if (pattern_chans[0] > 63 && pattern_chans[1] > 63 &&
        pattern_chans[2] > 63 && pattern_chans[3] > 63) {
        // Stop music on this channel
        chan->is_music = 0;
        chan->overlay_ptr = 0;
        chan->can_loop = 0;
        chan->total_samples = 0;
        chan->music_data_ptr = 0;
        return;
    }
    
    // Get the SFX for this channel
    int sfx_index = pattern_chans[chan->channel_index];
    SfxDef* new_sfx;
    if (sfx_index > 63)
        new_sfx = NULL;
    else
        new_sfx = &music->sfx_defs[max(sfx_index, 0)];
    
    chan->sfx_ptr = new_sfx;
    chan->tick = 0;
    chan->total_samples = 0;
    chan->crossfade_pos = 183;  // Force immediate render on next call
    chan->duration = Lq(music, pattern_chans);
    return;
}
```

---

## Kq - Effect & State Update

**Signature:** `Kq(channel, synth_state)`

Called once per tick. Reads the current SFX note, applies effects (slide, vibrato,
drop, fade, arpeggio), computes the final frequency and volume, and sets the
detune/buzz/reverb/dampen flags.

```c
void Kq(Channel* chan, SynthState* state) {
    SfxDef* sfx = chan->sfx_ptr;
    if (!sfx) {
        // No SFX: silence
        state->note_volume = 0;
        state->instrument = 0;
        state->phase_inc_primary = 0;
        return;
    }
    
    int speed = sfx->speed;
    speed = max(speed, 1);
    int tick = chan->tick;
    int note_index = tick / speed;
    int sub_tick = tick - note_index * speed;  // = tick % speed
    
    // If past end of SFX (note_index > 31), stop
    if (sfx == NULL || note_index > 31) {
        /* would have returned above */
    }
    
    bool speed_is_fast = sfx->speed < 9;
    int arp_divisor_fast = speed_is_fast ? 2 : 4;
    int arp_divisor_slow = speed_is_fast ? 4 : 8;
    
    // --- Read current note data ---
    Note* note = &sfx->notes[note_index];
    int instrument = note->instrument;
    state->instrument = instrument;
    int volume = note->volume;
    int volume_scaled = volume << 8;           // volume * 256
    state->note_volume = volume_scaled;        // +28
    int key = note->key;
    int pitch = key << 16;                     // key in 16.16 fixed point
    state->note_pitch = pitch;                 // +32
    state->raw_key = key;                      // +60
    state->raw_instrument = instrument;        // +64
    state->raw_volume = volume;                // +56
    
    int effect = note->effect;
    
    // --- Apply effect ---
    state->effect_type = 0;   // +68
    state->drop_factor = 0;   // +76 (via +72 initially)
    
    switch (effect) {
        case 0:  // No effect
            break;
            
        case 1:  // Slide
        {
            // Slide from previous note to current note
            if (note_index > 0) {
                int prev_key = chan->prev_key;       // +11908
                int prev_vol = chan->prev_volume;    // +11916, already << 8
            } else {
                int prev_key = 24;  // C-2 default
                int prev_vol = volume_scaled;
            }
            int remaining = speed - sub_tick;
            // Linear interpolation between prev and current
            pitch = (remaining * (prev_key << 16) + sub_tick * pitch) / speed;
            state->note_pitch = pitch;
            volume_scaled = (remaining * prev_vol + sub_tick * volume_scaled) / speed;
            state->note_volume = volume_scaled;
            break;
        }
        
        case 2:  // Vibrato
            // Handled via detune multiplier below
            break;
            
        case 3:  // Drop (pitch slide down)
            // No immediate pitch change; handled in drop_factor
            break;
            
        case 4:  // Fade in
        {
            volume_scaled = (volume_scaled * sub_tick) / speed;
            state->note_volume = volume_scaled;
            break;
        }
        
        case 5:  // Fade out
        {
            volume_scaled = (volume_scaled * (speed - sub_tick)) / speed;
            state->note_volume = volume_scaled;
            break;
        }
        
        case 6:  // Arpeggio fast
        {
            // Cycle through group of 4 notes
            int arp_note = ((tick / arp_divisor_fast) % 4) + (note_index & ~3);
            pitch = sfx->notes[arp_note].key << 16;
            state->note_pitch = pitch;
            break;
        }
        
        case 7:  // Arpeggio slow
        {
            int arp_note = ((tick / arp_divisor_slow) % 4) + (note_index & ~3);
            pitch = sfx->notes[arp_note].key << 16;
            state->note_pitch = pitch;
            break;
        }
    }
    
    state->base_key = key;
    state->envelope_volume = volume_scaled;
    
    // --- Apply envelope from custom instrument / SFX instrument reference ---
    // If the note has a custom flag, decode the referenced SFX as an instrument
    if (note->custom) {
        // Check whether to restart the envelope
        bool restart = false;
        if (sub_tick == 0) {
            bool note_changed = (effect != 1) && 
                ((note_index == 0) || (key != chan->prev_key));
            // ... complex restart logic involving envelope_tick and loop points
            if (note_changed || envelope_expired)
                restart = true;
            // For effects 4 (fade in) or 3 (drop), additional checks
            if (restart)
                chan->envelope_tick = 0;
        }
        
        // Call Mq to decode the instrument envelope
        Mq(chan, note, state);
        pitch = state->note_pitch;  // Mq may have modified it
    }
    
    // --- Half-rate pitch shift ---
    int chan_idx = chan->channel_index;
    int half_rate_mask = 1 << (chan_idx + 4);
    if (half_rate_mask & hw_half_rate_flags) {
        pitch -= 786432;  // Subtract 12 semitones (12 << 16) = one octave down
        state->note_pitch = pitch;
    }
    
    // === FREQUENCY CALCULATION ===
    // Convert 16.16 fixed-point pitch to phase increment
    
    int frac = pitch & 0xFFFF;       // Fractional semitone (0-65535)
    int semitone = pitch >> 16;       // Integer semitone
    
    // Compute octave: ((semitone + 48) / 12) - 4
    int octave = ((semitone + 48) / 12) - 4;
    
    // Note within octave (0-11), handling negative pitches
    int note_in_oct;
    if (pitch >= 0)
        note_in_oct = semitone % 12;
    else
        note_in_oct = (12 - ((-semitone) % 12)) % 12;
    
    // Look up frequency from table (12 entries for one octave, at byte offset 30112)
    // Table contains frequencies at 22050 Hz for octave 4, scaled by 65536
    // freq_table[0..12] for notes C through C+1
    int freq_lo = freq_table[note_in_oct];
    int freq_hi = freq_table[note_in_oct + 1];
    
    // Linear interpolation between semitones
    int base_freq = (freq_lo * (65536 - frac) + freq_hi * frac) / 22050;
    
    // Octave shifting
    if (pitch < 2359296) {  // < 36 semitones (octave 3)
        // Shift down
        while (octave < 2) {
            base_freq /= 2;
            octave++;
        }
    }
    if (octave > 3) {
        // Shift up
        while (octave > 4) {
            base_freq *= 2;
            octave--;
        }
    }
    // (octave 3 and 4 are the "neutral" range covered by the table)
    
    // Clamp frequency to [8, 32768]
    int freq = clamp(base_freq, 8, 32768);
    state->phase_inc_primary = freq;
    
    // === VIBRATO (effect 2) ===
    // Vibrato modifies frequency by a small detune amount
    // Uses tick position within note to create oscillation
    int effect_type = state->effect_type;  // from Mq or note data
    bool is_vibrato = (effect_type == 2);
    
    if ((effect == 2 && !is_vibrato) || (!is_vibrato && effect != 2)) {
        // Standard vibrato: multiply frequency based on tick sub-position
        // The detune amount depends on the tick position within the speed
        int tick_mod8 = (chan->tick >> 1) & 7;
        switch (tick_mod8) {
            case 1: freq = (freq * 129) >> 7; break;  // +0.78%
            case 2: freq = (freq * 130) >> 7; break;  // +2.34%
            case 3: freq = (freq * 129) >> 7; break;
            case 5: freq = (freq * 127) >> 7; break;  // -0.78%
            case 6: freq = (freq * 126) >> 7; break;  // -1.56%
            case 7: freq = (freq * 127) >> 7; break;
            // cases 0, 4: no change (zero crossings of triangle LFO)
        }
    } else if (effect == 2 && is_vibrato) {
        // Both note effect and instrument effect are vibrato: deeper modulation
        switch (tick_mod8) {
            case 1: freq = (freq * 130) >> 7; break;
            case 2: freq = (freq * 132) >> 7; break;  // +3.9% 
            case 3: freq = (freq * 130) >> 7; break;
            case 5: freq = (freq * 126) >> 7; break;
            case 6: freq = (freq * 124) >> 7; break;  // -3.1%
            case 7: freq = (freq * 126) >> 7; break;
        }
    }
    state->phase_inc_primary = freq;
    
    // === DROP EFFECT (effect 3) ===
    // When the instrument defines a drop, fade frequency to zero over the note duration
    MusicData* music = chan->music_data_ptr;
    int instr_idx = clamp(instrument, 0, 7);
    if (effect == 3) {
        if (note->custom && !(music->sfx_defs[instr_idx].loop_start & 128)) {
            // Custom instrument with valid envelope: don't apply extra drop
        } else {
            // Linear frequency fade over the note
            freq = (freq * (speed - sub_tick)) / speed;
            state->phase_inc_primary = freq;
        }
    }
    
    // === DROP from effect_flags ===
    if (state->drop_factor != 0) {
        // Apply additional drop from Mq
        freq = (freq * state->drop_factor) / 256;
        state->phase_inc_primary = freq;
    }
    
    // === VOLUME for music channels (fade in/out) ===
    if (chan->is_music) {
        int music_vol = (pcm_volume >> 8);
        int scaled_vol = (music_vol * state->note_volume) / 256;
        state->note_volume = (scaled_vol * master_music_volume) / 256;
    }
    
    // === DECODE FILTER FLAGS ===
    // SFX flags byte encodes: detune, buzz, noise modification, reverb, dampen
    // flags bits layout (from SFX definition flags field):
    //   (flags >> 3) % 3 = reverb (0, 1, 2)
    //   (flags >> 2) & 1 = buzz
    //   (flags >> 1) & 1 = noise_mod
    
    int sfx_flags = sfx->flags;
    int reverb_sfx = (sfx_flags >> 3) % 3;
    int buzz_sfx = (sfx_flags >> 2) & 1;
    
    int envelope_flags = state->effect_flags;
    int reverb_env = (envelope_flags >> 3) % 3;
    int buzz_env = (envelope_flags >> 2) & 1;
    
    int detune = max(reverb_sfx, reverb_env);
    state->detune_mode = detune;                // +80
    
    int buzz = max(buzz_sfx, buzz_env);
    state->buzz_flag = buzz;                    // +84
    
    int noise_sfx = (sfx_flags >> 1) & 1;
    int noise_env = (envelope_flags >> 1) & 1;
    int noise_mod = max(noise_sfx, noise_env);
    state->custom_or_noise_flag = noise_mod;    // +88
    
    // === VOLUME SCALING based on instrument and detune ===
    // Certain instruments get louder when detuned
    int final_vol = state->phase_inc_primary;  // actually uses freq for volume calc
    bool no_detune = (detune == 0);
    
    // Instrument-specific volume scaling
    int scaled_freq = freq;
    if (no_detune) {
        state->volume_out = (scaled_freq * 256) / 256;  // no change
    } else {
        state->volume_out = (scaled_freq * 255) / 256;  // slight reduction with detune
    }
    
    // For instruments < 6 with detune, boost note_volume by 5/4
    if (state->instrument < 6 && detune > 0) {
        state->note_volume = (state->note_volume * 5) / 4;
    }
    
    // Special handling for instrument 6 (noise) with noise_mod flag
    if (state->instrument == 6 && noise_mod != 0) {
        // Noise mod creates periodic noise resets
        int noise_timer = chan->noise_timer;  // at +11996
        if (noise_timer > 11) {
            state->custom_or_noise_flag = 2;
            chan->noise_timer = 0;
        }
    }
    
    // === DAMPEN LEVEL (per-note) ===
    int sfx_damp = sfx ? ((sfx->flags >> 3) / 3) % 3 : 0;
    int global_damp = ((chan->state_at_11628 >> 3) / 3) % 3;
    int per_note_damp = max(sfx_damp, global_damp);
    state->dampen_level = per_note_damp;        // +92
    
    // Hardware can force dampen
    if (hw_reverb_flags & (1 << (chan_idx + 4)))
        per_note_damp = max(per_note_damp, 1);
    if (hw_reverb_flags & (1 << chan_idx))
        per_note_damp = max(per_note_damp, 2);
    state->dampen_level = per_note_damp;
}
```

### Note on vibrato implementation

The vibrato in PICO-8 is **not** a smooth sine or triangle LFO. It is a
**stepped triangle wave** that cycles through 8 phases (indexed by `(tick>>1) & 7`),
creating a coarse vibrato that changes every 2 ticks. The depth is approximately
+/- 2-4% frequency variation (about +/- 0.3 to 0.7 semitones).

When both the SFX note effect AND the custom instrument effect are both vibrato,
the depth is roughly doubled.

---

## Mq - Envelope / SFX Note Decoder

**Signature:** `Mq(channel, note_ptr, synth_state)`

When a note references a custom instrument (SFX 0-7 used as instrument), this
function reads the note data from that instrument SFX and applies it as an
envelope/timbre modulator to the current note.

```c
void Mq(Channel* chan, Note* note, SynthState* state) {
    MusicData* music = chan->music_data_ptr;
    if (!music) return;
    
    int instr_ref = note->instrument;
    instr_ref = clamp(instr_ref, 0, 7);
    
    // Set effect_flags from the referenced instrument
    state->effect_flags = music->sfx_defs[instr_ref].flags;
    
    int loop_flags = music->sfx_defs[instr_ref].loop_start;
    
    // === CUSTOM WAVEFORM (loop_start has bit 7 set) ===
    if (loop_flags & 128) {
        // This SFX is a custom waveform definition (not a melodic instrument)
        state->instrument = 8;  // Set to "custom waveform" type
        
        // If speed is odd, shift pitch down one octave
        if (music->sfx_defs[instr_ref].speed & 1) {
            state->note_pitch -= 786432;  // -= 12 << 16
        }
        
        // Decode 32 notes into 64 waveform samples (2 samples per note)
        for (int i = 0; i < 32; i++) {
            Note* wn = &music->sfx_defs[instr_ref].notes[i];
            int key = wn->key;
            int instr = wn->instrument;
            int vol = wn->volume;
            int effect = wn->effect;
            int custom = wn->custom;
            
            // Pack into two 9-bit signed values
            int sample_even = (instr << 6 & 192) | key;
            sample_even = (sample_even - (sample_even << 1 & 256)) << 7;  // sign-extend 9-bit
            
            int sample_odd = (vol << 1 & 14) | (instr >> 2 & 1) | 
                            (effect << 4 & 112) | (custom & 128);
            sample_odd = (sample_odd - (custom << 1 & 256)) << 7;  // sign-extend 9-bit
            
            state->custom_waveform[i * 2]     = sample_even;  // +96 + i*8
            state->custom_waveform[i * 2 + 1] = sample_odd;   // +96 + i*8 + 4
        }
        
        state->effect_type = 0;
        return;
    }
    
    // === MELODIC INSTRUMENT ===
    int speed = music->sfx_defs[instr_ref].speed;
    speed = max(speed, 1);
    bool speed_is_fast = speed < 9;
    int arp_fast_div = speed_is_fast ? 2 : 4;
    int arp_slow_div = speed_is_fast ? 4 : 8;
    
    int loop_end = music->sfx_defs[instr_ref].loop_end;
    int envelope_tick = chan->envelope_tick;
    
    // Clamp envelope_tick if it exceeds loop bounds
    if (loop_end <= loop_flags || envelope_tick >= loop_end * speed) {
        // Past the loop: clamp
        envelope_tick = min(envelope_tick, loop_flags * speed - 1);  // ... complex logic
    }
    
    int env_note_idx = envelope_tick / speed;
    int env_sub_tick = envelope_tick - env_note_idx * speed;
    
    if (env_note_idx > 31 || env_note_idx >= effective_end) {
        // Past end of instrument: silence
        state->note_volume = 0;
        state->instrument = 0;
        return;
    }
    
    // Clamp note index
    env_note_idx = clamp(env_note_idx, 0, 31);
    
    // Read instrument note
    Note* env_note = &music->sfx_defs[instr_ref].notes[env_note_idx];
    int env_key = env_note->key;
    int env_key_fp = env_key << 16;        // 16.16 fixed point
    int env_vol = env_note->volume;
    int env_vol_scaled = env_vol << 8;     // * 256
    
    // Save for next tick's slide
    if (env_sub_tick == speed - 1) {
        chan->prev_mq_key = env_key;
        chan->prev_mq_vol = env_vol;
        chan->prev_mq_instr = env_note->instrument;
    }
    
    int env_effect = env_note->effect;
    
    switch (env_effect) {
        case 1:  // Slide from previous envelope note
        {
            int prev_key_fp;
            int prev_vol;
            if (env_note_idx > 0) {
                prev_key_fp = chan->prev_mq_key << 16;
                prev_vol = chan->prev_mq_vol << 8;
            } else {
                prev_key_fp = 1572864;  // 24 << 16 (C-2)
                prev_vol = env_vol_scaled;
            }
            int remaining = speed - env_sub_tick;
            env_key_fp = (prev_key_fp * remaining + env_sub_tick * (env_key << 16)) / speed;
            env_vol_scaled = (prev_vol * remaining + env_vol_scaled * env_sub_tick) / speed;
            break;
        }
        
        case 3:  // Drop
        {
            // Set drop_factor for Kq to apply
            state->drop_factor = ((speed - env_sub_tick) << 8) / speed;
            break;
        }
        
        case 4:  // Fade in
        {
            env_vol_scaled = (env_vol_scaled * env_sub_tick) / speed;
            break;
        }
        
        case 5:  // Fade out
        {
            env_vol_scaled = (env_vol_scaled * (speed - env_sub_tick)) / speed;
            break;
        }
        
        case 6:  // Arpeggio fast
        {
            int arp_idx = ((envelope_tick / arp_fast_div) % 4) + (env_note_idx & ~3);
            env_key_fp = music->sfx_defs[instr_ref].notes[arp_idx].key << 16;
            break;
        }
        
        case 7:  // Arpeggio slow
        {
            int arp_idx = ((envelope_tick / arp_slow_div) % 4) + (env_note_idx & ~3);
            env_key_fp = music->sfx_defs[instr_ref].notes[arp_idx].key << 16;
            break;
        }
    }
    
    // Set instrument from envelope note
    int env_instr = env_note->instrument;
    state->instrument = env_instr;
    
    // If the envelope note itself references a custom waveform, decode it
    if (env_note->custom) {
        int sub_ref = clamp(env_instr, 0, 7);
        if (music->sfx_defs[sub_ref].loop_start & 128) {
            // It's a custom waveform SFX
            state->effect_flags = music->sfx_defs[sub_ref].flags;
            state->instrument = 8;
            if (music->sfx_defs[sub_ref].speed & 1)
                state->note_pitch -= 786432;
            
            // Decode waveform (same as above)
            for (int i = 0; i < 32; i++) {
                /* ... same custom waveform decode ... */
            }
        }
    }
    
    // === Apply envelope modulation to note ===
    // Pitch: offset from C-2 (key 24, pitch 1572864)
    state->note_pitch += env_key_fp - 1572864;
    
    // Key offset
    state->base_key += env_note->key - 24;
    
    // Volume: scale by envelope volume / max_speed
    int vol_per_speed = (env_vol_scaled * 7) / max(speed, 1);
    state->envelope_volume = vol_per_speed;
    
    // Volume: scale note_volume by envelope ratio
    state->note_volume = (state->note_volume * env_vol_scaled) / 1792;
    
    state->effect_type = env_effect;
}
```

---

## Jq - Waveform Renderer

**Signature:** `Jq(synth_state, output, num_samples, channel)`

The core waveform generator. Produces `num_samples` (typically 183) 16-bit samples
based on the synth state. Implements all 8 built-in waveforms plus custom waveforms.

All waveforms use 16-bit phase accumulators that wrap naturally. The primary oscillator
phase wraps at 65536 (16-bit), the secondary at 131072 (17-bit) for detune effects.

The volume is `(note_pitch * 3) / 2` where note_pitch comes from the SFX data,
then output is divided by 3072 to normalize to int16 range.

```c
// Frequency table for one octave (C through C, 13 entries)
// These are phase increments per sample at 22050 Hz for octave 4
// Stored at byte offset 30112 in the heap
static const int32_t freq_table[13] = {
    // Approximate values (need to extract from binary data segment):
    // C4, C#4, D4, D#4, E4, F4, F#4, G4, G#4, A4, A#4, B4, C5
    // At 22050 Hz: freq * 65536 / 22050
    // A4=440Hz -> 440*65536/22050 = 1306087 (approx)
    // These are pre-computed for the octave containing A=440Hz
};

void Jq(SynthState* st, int16_t* out, int num_samples, Channel* chan) {
    bool has_buzz = (st->buzz_flag != 0);     // +84
    int detune_mode = st->detune_mode;        // +80
    int note_volume_raw = st->note_volume;    // +28
    int instrument = st->instrument;          // +0
    
    // If instrument is 0 AND no custom waveform data in channel
    if (instrument == 0 && chan->hw_reverb_level == 0) {
        st->phase_primary = 0;
        memset(out, 0, num_samples * 2);
        return;
    }
    
    int phase = st->phase_primary;              // +4, 16-bit wrapping
    int phase_inc = st->phase_inc_primary;      // +8
    int phase2 = st->phase_secondary;           // +12, 17-bit wrapping  
    int phase_inc2 = st->phase_inc_secondary;   // +16
    // For detune: secondary oscillator runs at same rate by default
    // but the phase relationship creates the detune effect
    
    int volume = (note_volume_raw * 3) / 2;    // Scale volume
    // "p" in the original code
    
    bool is_stereo = (num_samples > 0);
    
    // =================================================================
    // INSTRUMENT 8: CUSTOM WAVEFORM
    // =================================================================
    if (instrument == 8 && num_samples > 0) {
        int shift = (detune_mode == 2) ? 1 : 0;  // detune 2 doubles phase for custom
        for (int i = 0; i < num_samples; i++) {
            // Read from 64-entry custom waveform table using phase as index
            // Phase is 16-bit (0-65535), table has 64 entries
            // Index = (phase >> 10) & 63  (top 6 bits)
            int idx = (phase >> 10) & 63;
            int val = st->custom_waveform[idx];
            // Linear interpolation to next sample
            int idx_next = ((phase + 1024) >> 10) & 63;
            int val_next = st->custom_waveform[idx_next];
            int frac = phase & 1023;
            int interp = ((val_next - val) * frac + (val << 10)) >> 10;
            
            // Secondary oscillator for detune
            int p2 = phase2 << shift;
            int idx2 = (p2 >> 10) & 63;
            int val2 = st->custom_waveform[idx2];
            int idx2_next = ((p2 + 1024) >> 10) & 63;
            int val2_next = st->custom_waveform[idx2_next];
            int interp2 = ((val2_next - val2) * (p2 & 1023) + (val2 << 10)) >> 10;
            
            phase = (phase + phase_inc) & 0xFFFF;
            phase2 = (phase2 + phase_inc2) & 0x1FFFF;
            
            out[i] = (interp / 2 + interp2) * volume / 3072;
        }
        goto finish;
    }
    
    // =================================================================
    // INSTRUMENT 0 & 7: TRIANGLE / PHASER (handled together)
    // =================================================================
    // Original has: case 0 and case 7 share the same initial code path
    if (instrument == 0 || instrument == 7) {
        if (num_samples > 0) {
            for (int i = 0; i < num_samples; i++) {
                // Triangle wave: ramp up 0-16383, ramp down 16384-49151, ramp up 49152-65535
                // Formula: if phase < 32768: (phase*3) - 49152 mapped to [-16384, 16384]
                //          else: (49152-phase)*3
                int tri;
                if (phase & 0x8000)  // phase >= 32768
                    tri = (49152 - phase) * 3;
                else
                    tri = phase * 3 - 49152;
                
                int sample_primary, sample_secondary;
                
                if (has_buzz) {
                    // Buzz adds a tilted-saw component mixed with the triangle
                    // For the primary oscillator:
                    int threshold = 57344;  // ~87.5% of 65536
                    int norm;
                    if (phase > threshold)
                        norm = ((65535 - phase) * 24572) / (65536 - threshold);
                    else
                        norm = (phase * 24572) / threshold;
                    sample_primary = (tri / 4) * 3 - 12286 + norm;
                    
                    // For the secondary oscillator:
                    int p2 = phase2 & 0xFFFF;
                    int tri2;
                    if (p2 & 0x8000)
                        tri2 = (49152 - p2) * 3;
                    else
                        tri2 = p2 * 3 - 49152;
                    int norm2;
                    if (p2 > threshold)
                        norm2 = ((65535 - p2) * 24572) / (65536 - threshold);
                    else
                        norm2 = (p2 * 24572) / threshold;
                    sample_secondary = (tri2 / 4) * 3 - 12286 + norm2;
                } else {
                    sample_primary = tri;
                    int p2 = phase2 & 0xFFFF;
                    int tri2;
                    if (p2 & 0x8000)
                        tri2 = (49152 - p2) * 3;
                    else
                        tri2 = p2 * 3 - 49152;
                    sample_secondary = tri2;
                }
                
                phase = (phase + phase_inc) & 0xFFFF;
                phase2 = (phase2 + phase_inc2) & 0x1FFFF;
                
                out[i] = ((sample_primary / 4) + (sample_secondary / 8)) * volume / 3072;
            }
        }
    }
    
    // =================================================================
    // INSTRUMENT 1: TILTED SAW
    // =================================================================
    if (instrument == 1 && num_samples > 0) {
        int shift = (detune_mode == 2) ? 1 : 0;
        for (int i = 0; i < num_samples; i++) {
            int L_val, M_val;  // primary and secondary contributions
            
            if (has_buzz) {
                // Buzz: threshold at ~93.75% (61440)
                int threshold = 61440;
                if (phase > threshold)
                    L_val = ((65535 - phase) * 24572) / (65536 - threshold);
                else
                    L_val = (phase * 24572) / threshold;
                
                int p2 = (phase2 << shift) & 0xFFFF;
                if (p2 > threshold)
                    M_val = ((65535 - p2) * 24572) / (65536 - threshold);
                else
                    M_val = (p2 * 24572) / threshold;
            } else {
                // Normal: threshold at ~87.5% (57344)
                int threshold = 57344;
                if (phase > threshold)
                    L_val = ((65535 - phase) * 24572) / (65536 - threshold);
                else
                    L_val = (phase * 24572) / threshold;
                
                int p2 = (phase2 << shift) & 0xFFFF;
                if (p2 > threshold)
                    M_val = ((65535 - p2) * 24572) / (65536 - threshold);
                else
                    M_val = (p2 * 24572) / threshold;
            }
            
            phase = (phase + phase_inc) & 0xFFFF;
            phase2 = (phase2 + phase_inc2) & 0x1FFFF;
            
            out[i] = ((L_val - 12286) + (M_val - 12286) / 2) * volume / 3072;
        }
    }
    
    // =================================================================
    // INSTRUMENT 2: SAW
    // =================================================================
    if (instrument == 2 && num_samples > 0) {
        int shift = (detune_mode == 2) ? 1 : 0;
        for (int i = 0; i < num_samples; i++) {
            int Q_val, R_val;
            int p2 = phase2 << shift;
            
            if (has_buzz) {
                // Buzz: half-wave rectified saw with offset
                Q_val = (((p2 & 0xFFFF) - 32768) / 4 + ((p2 / 2 - 32768) / 4));
                R_val = ((phase - 32768) / 4 + ((phase / 2 - 32768) / 4)) / 2;
                // Divide by 2 instead of 4 for primary in buzz mode
            } else {
                Q_val = (p2 & 0xFFFF) - 32768;  // Full saw: -32768 to 32767
                R_val = (phase - 32768) / 4;
            }
            
            phase = (phase + phase_inc) & 0xFFFF;
            phase2 = (phase2 + phase_inc2) & 0x1FFFF;
            
            int denominator = has_buzz ? 2 : 4;
            out[i] = ((Q_val / denominator / 2) + R_val) * volume / 3072;
        }
    }
    
    // =================================================================
    // INSTRUMENTS 3 & 4: SQUARE / PULSE
    // =================================================================
    // These share the same code with different duty cycle thresholds
    if ((instrument == 3 || instrument == 4) && num_samples > 0) {
        int duty = (instrument == 3) ? 32768 : 45056;
        // Buzz shifts the duty cycle
        int threshold = has_buzz ? duty + 6144 : duty;
        
        if (detune_mode == 2) {
            // Detune 2: secondary oscillator doubled
            for (int i = 0; i < num_samples; i++) {
                int pri = (phase < threshold) ? -6143 : 6143;
                int sec = ((phase2 << 1) & 0xFFFF) < threshold ? -3071 : 3071;
                
                phase = (phase + phase_inc) & 0xFFFF;
                phase2 = (phase2 + phase_inc2) & 0x1FFFF;
                
                out[i] = (pri + sec) * volume / 3072;
            }
        } else {
            for (int i = 0; i < num_samples; i++) {
                int pri = (phase < threshold) ? -6143 : 6143;
                int sec = ((phase2 & 0xFFFF) < threshold) ? -3071 : 3071;
                
                phase = (phase + phase_inc) & 0xFFFF;
                phase2 = (phase2 + phase_inc2) & 0x1FFFF;
                
                out[i] = (pri + sec) * volume / 3072;
            }
        }
    }
    
    // =================================================================
    // INSTRUMENT 5: ORGAN
    // =================================================================
    if (instrument == 5 && num_samples > 0) {
        int shift = (detune_mode == 2) ? 1 : 0;
        
        if (has_buzz) {
            // Buzz: add a sub-harmonic pulse
            int sub_threshold = 32768 >> shift;
            for (int i = 0; i < num_samples; i++) {
                // Organ: two triangles at different rates
                // First half: triangle with 3x period stretch
                // Second half: triangle at normal rate
                int organ;
                if (phase & 0x4000) {  // bit 14 set
                    if (!(phase & 0x8000))
                        organ = 32768 - phase;
                    else
                        organ = ((65536 - phase - 32768) << 1) / 3;
                } else {
                    if (!(phase & 0x8000))
                        organ = phase;
                    else
                        organ = ((phase - 32768) << 1) / 3;
                }
                
                // Sub-harmonic square
                int sub = (phase2 & sub_threshold) == 0 ? -1535 : 1535;
                
                phase = (phase + phase_inc) & 0xFFFF;
                phase2 = (phase2 + phase_inc2) & 0x1FFFF;
                
                out[i] = (organ - 8192 + sub) * volume / 3072;
            }
        } else {
            for (int i = 0; i < num_samples; i++) {
                int organ;
                if (phase & 0x4000) {
                    if (!(phase & 0x8000))
                        organ = 32768 - phase;
                    else
                        organ = ((65536 - phase - 32768) << 1) / 3;
                } else {
                    if (!(phase & 0x8000))
                        organ = phase;
                    else
                        organ = ((phase - 32768) << 1) / 3;
                }
                
                // Secondary organ
                int p2 = (phase2 << shift) & 0xFFFF;
                int organ2;
                if (p2 & 0x4000) {
                    if (!(p2 & 0x8000))
                        organ2 = 32768 - p2;
                    else
                        organ2 = ((65536 - p2 - 32768) << 1) / 3;
                } else {
                    if (!(p2 & 0x8000))
                        organ2 = p2;
                    else
                        organ2 = ((p2 - 32768) << 1) / 3;
                }
                
                phase = (phase + phase_inc) & 0xFFFF;
                phase2 = (phase2 + phase_inc2) & 0x1FFFF;
                
                out[i] = (organ - 8192 + (organ2 - 8192) / 2) * volume / 3072;
            }
        }
    }
    
    // =================================================================
    // INSTRUMENT 6: NOISE
    // =================================================================
    if (instrument == 6) {
        int noise_timer_ptr = &st->noise_timer;  // +88 actually chan->noise_timer
        
        if (chan->custom_or_noise_flag != 0) {
            // === MODE A: Periodic noise (noise_mod flag set) ===
            // Sample-and-hold random values at a rate determined by pitch
            int period = 64 - (st->note_pitch >> 16);
            period = max(period, 1);
            if (period > 63) period = (period * 4) - 192;
            
            if (num_samples > 0) {
                int counter = st->noise_counter;  // +44
                for (int i = 0; i < num_samples; i++) {
                    if (counter == 0) {
                        // Generate new sample pair
                        st->noise_prev_sample = st->noise_cur_sample;
                        st->noise_cur_sample = pp(12286) - 6143;  // random in [-6143, 6143]
                        out[i] = st->noise_prev_sample * volume / 2048;
                    } else {
                        // Crossfade during transition
                        if (chan->custom_or_noise_flag > 1) {
                            int t_fade = period - counter;
                            int t_total = period;
                            int blended = (st->noise_cur_sample * t_fade + 
                                          st->noise_prev_sample * counter);
                            out[i] = blended * volume / (2048 * t_total);
                        } else {
                            out[i] = st->noise_prev_sample * volume / 2048;
                        }
                    }
                    counter = (counter + 1) % period;
                    st->noise_counter = counter;
                }
            }
        } else {
            // === MODE B: Filtered white noise ===
            // Classic noise algorithm: IIR-filtered random walk
            int pitch_val = phase_inc;
            int aa;
            if (pitch_val > 78)
                aa = (pitch_val * 8) + 1120;
            else
                aa = (79 - pitch_val) * (-60) + 1752;
            aa = max(aa, 0);
            int half_aa = aa / 2;
            
            int metallic = has_buzz ? 0 : st->metallic_factor;  // +40
            // metallic factor creates pitched noise by mixing deterministic pulses
            
            if (num_samples > 0) {
                int flipflop = st->noise_flipflop;  // +24
                int noise_val = st->noise_sample;   // +20
                int filter_k = st->base_key;        // +36
                int O_val = (pitch_val + 500) / 3;  // threshold for metallic mixing
                
                for (int i = 0; i < num_samples; i++) {
                    // Alternating random walk
                    flipflop ^= 1;
                    st->noise_flipflop = flipflop;
                    
                    if (flipflop) {
                        // Apply random step
                        int step = pp(aa) - half_aa;
                        noise_val += step;
                    }
                    
                    // Metallic noise: mix deterministic signal based on phase
                    if (metallic != 0) {
                        if (((phase + 101) * (phase + 317) & 8191) < O_val) {
                            int pulse = (pp(12286) - 6143) * metallic / 1792;
                            noise_val += pulse;
                        }
                    }
                    
                    // Soft limiter
                    int k = filter_k;
                    int cutoff = (2048 / (max(k, 48) + 16)) + 48;
                    cutoff = max(cutoff, 64);
                    
                    // Clamp noise
                    noise_val = clamp(noise_val, -6143, 6143);
                    st->noise_sample = noise_val;
                    
                    // Output with variable gain
                    out[i] = (noise_val >> 6) * volume * cutoff / 2048;
                    
                    phase = (phase + phase_inc) & 0xFFFF;
                }
            }
        }
    }
    
finish:
    // === Save phase state ===
    st->phase_primary = phase;     // +4 (was 'A' in original, now U)
    st->phase_secondary = phase2;  // +12 (was 'C' in original, now V)
    
    // === REVERB (applied after waveform) ===
    int reverb_level = st->dampen_level;  // +92, actually reverb from Kq
    if (reverb_level <= 0) return;
    
    // Look up the correct reverb ring buffer entry
    int ring_idx = chan->reverb_write_idx;
    int delay = (reverb_level == 1) ? 2 : 4;  // 2 or 4 ticks of delay
    int read_idx = ring_idx - delay;
    if (read_idx < 0) read_idx = 8 - ((-read_idx) % 8);
    read_idx = read_idx % 8;
    
    if (num_samples > 0) {
        for (int i = 0; i < num_samples; i++) {
            // Mix reverb: out[i] = (reverb_old * 2 + out[i] * 4) / 4
            // This is approximately: out += 0.5 * delayed_signal
            int16_t delayed = chan->reverb_ring[read_idx][i];
            out[i] = (delayed * 2 + out[i] * 4) / 4;
            // Actually more like: ((delayed << 1) + (out[i] << 2)) / 4
            // = delayed/2 + out[i]
        }
    }
}
```

### Waveform Summary Table

| ID | Name | Description | Buzz Modification |
|----|------|-------------|-------------------|
| 0 | Triangle | Symmetric triangle, +-16384 | Adds tilted-saw component (87.5% duty), mixed 75/25 |
| 1 | Tilted Saw | Asymmetric triangle (87.5% rise, 12.5% fall) | Threshold shifts to 93.75% |
| 2 | Saw | Linear sawtooth | Half-wave rectified, doubled amplitude |
| 3 | Square | 50% duty cycle square | Duty shifts to ~59.4% |
| 4 | Pulse | ~68.8% duty cycle | Duty shifts to ~78.1% |
| 5 | Organ | Two-segment triangle (different slopes) | Adds sub-harmonic square pulse |
| 6 | Noise | IIR-filtered random walk | Adds pitched metallic component |
| 7 | Phaser | Same as triangle but with phase2 detune | Same as triangle buzz |
| 8 | Custom | 64-sample wavetable with interpolation | Detune doubles secondary phase |

---

## Lq - Duration Calculation

**Signature:** `Lq(music_data, pattern_channels)`

Calculates the duration (in ticks) for a music pattern by examining all 4 channels
and finding the appropriate loop/end point.

```c
int Lq(MusicData* music, int* pattern_chans) {
    // pattern_chans is an array of 4 SFX indices for this pattern's channels
    
    // First pass: find a channel with a non-looping endpoint
    // (i.e., loop_end <= loop_start, meaning the SFX plays once and stops)
    for (int i = 0; i < 4; i++) {
        int sfx_idx = pattern_chans[i];
        if (sfx_idx >= 64) continue;
        
        SfxDef* sfx = &music->sfx_defs[sfx_idx];
        int loop_start = sfx->loop_start;
        int loop_end = sfx->loop_end;
        
        if (loop_start & 128) continue;  // custom waveform, skip
        if (loop_end > loop_start) continue;  // has a loop, skip
        
        // This SFX has a definite end
        int speed = max(sfx->speed, 1);
        int effective_end;
        if (!(loop_start & 128)) {
            effective_end = (loop_start > 0 && loop_end == 0) ? loop_start : 32;
        } else {
            effective_end = 0;
        }
        return effective_end * speed;
    }
    
    // Second pass: all channels are looping, find the longest one
    // (duration = when all channels have completed at least one full cycle)
    int max_duration = 0;
    for (int i = 0; i < 4; i++) {
        int sfx_idx = pattern_chans[i];
        if (sfx_idx >= 64) continue;
        
        SfxDef* sfx = &music->sfx_defs[sfx_idx];
        int speed = max(sfx->speed, 1);
        int loop_start = sfx->loop_start;
        int loop_end = sfx->loop_end;
        
        int effective_end;
        if (!(loop_start & 128)) {
            effective_end = (loop_start > 0 && loop_end == 0) ? loop_start : 32;
        } else {
            effective_end = 0;
        }
        int duration = effective_end * speed;
        max_duration = max(max_duration, duration);
    }
    
    return max_duration;
}
```

---

## pp - PRNG

**Signature:** `pp(range) -> int`

Simple 32-bit PRNG using rotate-and-add. Returns a value in `[0, range)`.

```c
// Global state at addresses 8734*4=34936 and 8735*4=34940
static uint32_t prng_state_a;  // c[8734]
static uint32_t prng_state_b;  // c[8735]

int pp(int range) {
    if (range == 0) return 0;
    
    // Rotate left 16 + add
    uint32_t a = prng_state_a;
    uint32_t b = prng_state_b;
    uint32_t new_a = (a << 16 | a >> 16) + b;
    prng_state_a = new_a;
    prng_state_b = new_a + b;
    
    return new_a % range;
}
```

---

## Differences from fake-08

### Architecture

| Aspect | PICO-8 (real) | fake-08 (zepto-8 based) |
|--------|--------------|------------------------|
| **Sample rate** | 22050 Hz fixed internally | 22050 Hz |
| **Processing** | All integer (16-bit samples, 32-bit math) | Float-point throughout |
| **Phase accumulator** | 16-bit unsigned (0-65535) wrapping | Float (0.0-1.0) normalized |
| **Volume representation** | Integer 0-1792 (7 * 256) | Float 0.0-1.0 |
| **Tick size** | Exactly 183 samples, processed as a block | Sample-by-sample with floating-point offset |
| **Crossfade** | 64-sample linear crossfade between ticks | Detect harsh changes, fade over ~130 samples |
| **Number of channels** | 16 (4 + 4 doubled + 8 half-rate) | 4 |
| **Mixing** | Hierarchical pair-wise with soft clip at 24575 | Simple summation with clamp |

### Waveform Differences

1. **Triangle (0)**: PICO-8 uses integer math `(phase*3 - 49152)` with explicit buzz mixing at 75/25 ratio. fake-08 uses `1.0 - |4t - 2|` which is equivalent but the buzz handling differs (fake-08 uses a fixed 0.875 threshold tilted saw).

2. **Tilted Saw (1)**: PICO-8 uses two different thresholds: 57344 (normal) and 61440 (buzz), computed with integer division. fake-08 uses 0.875 and 0.975 float thresholds -- these match.

3. **Saw (2)**: PICO-8's buzz mode uses half-wave addition `(x/2 - 32768)/4 + (x - 32768)/4` creating a different harmonic profile. fake-08 uses `0.83*t - offset` which is an approximation.

4. **Square/Pulse (3,4)**: PICO-8 uses fixed integer thresholds (32768/45056) with buzz adding 6144. fake-08 uses 0.5/0.316 with buzz at 0.4/0.255 -- the pulse width values don't exactly match (PICO-8's 45056/65536 = 0.6875, fake-08 uses 0.316).

5. **Organ (5)**: PICO-8 uses a two-segment triangle: `phase < 0.5: ramp with 3x stretch; phase >= 0.5: simple triangle`. The buzz adds a sub-harmonic square wave. fake-08's formula is `3 - |24t-6|` and `1 - |16t-12|` which produces a different shape.

6. **Noise (6)**: This is the **biggest difference**. PICO-8 uses:
   - A **clamped random walk** (NOT an IIR filter): each sample adds a random step, clamped to [-6143, 6143]
   - A flip-flop that only applies the random step on every other sample (creating a natural 2x oversampling smoothness)
   - Step size depends on frequency: `max(0, (freq>78) ? freq*8+1120 : (79-freq)*(-60)+1752)`
   - Variable output gain: `gain = max(64, 2048/(max(key,48)+16) + 48)` -- higher pitches are quieter
   - A "metallic" mode (when buzz flag is clear) that mixes deterministic phase-based random pulses, creating pitched noise
   - The metallic mixing threshold uses: `((phase+101) * (phase+317)) & 8191 < (freq+500)/3`
   
   fake-08 uses a fundamentally different algorithm:
   - Standard 1-pole IIR filter: `(last + scale * random) / (1 + scale)` -- smooth exponential decay
   - Fixed scale factor based on key: `22050 / key_to_freq(63) * (advance - last_advance)`
   - Volume uses `1.5 * (1 + factor^2)` where factor = `1 - key/63`
   - No metallic/deterministic component
   - No flip-flop alternation
   - The result sounds similar but lacks the characteristic "grittiness" of PICO-8's random walk

7. **Phaser (7)**: In PICO-8, phaser shares the triangle code path (instruments 0 and 7 use identical waveform generation). The "phaser" effect comes from the secondary oscillator running at a slightly different rate. fake-08 implements it as sum of two triangles at freq and freq*109/110, which is a different approach.

8. **Custom (8)**: PICO-8 reads a 64-entry wavetable with linear interpolation, where the table is packed from SFX note data (2 samples per note, 9-bit signed). fake-08 plays the custom SFX as a separate sfx_state with frequency scaling.

### Effect Differences

1. **Vibrato**: PICO-8 uses a **stepped 8-phase triangle LFO** (changes every 2 ticks) with approximately +/- 1-3% frequency deviation. fake-08 uses a smooth triangle at 7.5 Hz with half-semitone depth. The PICO-8 approach is much more coarse/stepped.

2. **Arpeggio**: PICO-8 divides the tick counter by (2 or 4) for fast, (4 or 8) for slow, with the divisor depending on whether speed < 9. fake-08 uses `7.5 * offset / offset_per_second` which is a continuous calculation.

3. **Slide**: PICO-8 interpolates in 16.16 fixed-point pitch space (linear in semitones). fake-08 interpolates in frequency space via `key_to_freq(prev)` to `key_to_freq(cur)`, which produces exponential pitch curves rather than linear.

4. **Drop**: PICO-8 linearly fades frequency from full to zero over the note duration using integer multiplication. Equivalent to fake-08's `freq *= 1 - fmod(offset, 1)`.

5. **Fade in/out**: Both implementations are equivalent (linear volume ramp).

### Filter Differences  

1. **Reverb**: PICO-8 uses a ring buffer of the last 8 ticks (8 * 183 = 1464 samples), reading back 2 or 4 ticks for reverb levels 1 and 2. The delayed signal is mixed at 50% amplitude. fake-08 uses separate float buffers of 366 and 732 samples.

2. **Dampen (Low-pass)**: PICO-8 uses a simple 1-pole IIR: `y[n] = (damp * y[n-1] + (16-damp) * x[n]) / 16` where damp is 0, 8, 12, or 15 (heavier = more filtering). fake-08 uses biquad high-shelf filters at specific frequencies, which is a more sophisticated but different approach.

3. **Detune**: PICO-8 implements detune via a secondary oscillator (phase2) running at the same frequency but with independent 17-bit phase, creating a natural beating effect. The secondary is mixed at half amplitude. fake-08 computes explicit frequency ratios (e.g., 200/199) per instrument type and renders a second waveform copy.

### Soft Clipping

PICO-8's soft clipping in the mixer is: values beyond +/-24575 are compressed by dividing the excess by 5. This prevents hard clipping while preserving dynamics. fake-08 uses simple `clamp(-1, 1)` which hard-clips.

### Envelope / Custom Instruments

PICO-8's custom instrument system (Mq) is significantly more detailed than fake-08's. It:
- Tracks a separate envelope tick counter per channel
- Supports all 8 effects within the instrument envelope
- Can nest custom waveform references (instrument -> SFX -> custom waveform)
- Applies pitch as an offset from C-2 (key 24) rather than a frequency ratio
- Handles slide between envelope notes with proper state tracking
