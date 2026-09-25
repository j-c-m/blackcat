use image::codecs::gif::GifDecoder;
use image::codecs::png::PngDecoder;
use image::codecs::webp::WebPDecoder;
use image::{
    metadata::LoopCount, AnimationDecoder, DynamicImage, Frame, ImageDecoder, ImageFormat,
};
use std::fs::File;
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};

use crate::kitty::{self, KittyFormat};

pub fn is_image(head: &[u8]) -> bool {
    image::guess_format(head).is_ok()
}

pub fn render(file: &mut File, out: &mut impl Write) -> io::Result<()> {
    file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    if let Some(anim) = decode_animated(&bytes) {
        return render_frames(anim, out);
    }
    let img = image::load_from_memory(&bytes)
        .map_err(|err| io::Error::new(io::ErrorKind::InvalidData, err))?;
    let (fit_w, fit_h) = fit_to_window(img.width(), img.height());
    write!(out, "\n     ")?;
    let use_shm = crate::shm::shm_ready();
    transmit_still(&img, out, fit_w, fit_h, use_shm)?;
    write!(out, "\n\n")?;
    out.flush()?;
    Ok(())
}

pub fn transmit_still(
    img: &DynamicImage,
    out: &mut impl Write,
    fit_w: u32,
    fit_h: u32,
    use_shm: bool,
) -> io::Result<()> {
    let (pixels, width, height, format) = fit_wire(img, fit_w, fit_h);
    if pixels.is_empty() {
        return Ok(());
    }
    if use_shm {
        match crate::shm::transmit_shm(out, &pixels, width, height, format)? {
            crate::shm::ShmSend::Sent => return Ok(()),
            crate::shm::ShmSend::LocalFail => {}
        }
    }
    let compressed = kitty::zlib_compress(&pixels)?;
    kitty::write_direct_apc(out, &compressed, width, height, format)
}

fn fit_wire(img: &DynamicImage, fit_w: u32, fit_h: u32) -> (Vec<u8>, u32, u32, KittyFormat) {
    let src_w = img.width();
    let src_h = img.height();
    let shrink = fit_w > 0 && fit_h > 0 && (fit_w < src_w || fit_h < src_h);
    let (dst_w, dst_h) = if shrink {
        (fit_w, fit_h)
    } else {
        (src_w, src_h)
    };
    match img {
        DynamicImage::ImageRgb8(buf) => (
            scale_packed(buf.as_raw(), src_w, src_h, 3, 3, dst_w, dst_h),
            dst_w,
            dst_h,
            KittyFormat::Rgb,
        ),
        DynamicImage::ImageLuma8(buf) => {
            let mut rgb = Vec::with_capacity(buf.len() * 3);
            for px in buf.as_raw() {
                rgb.extend_from_slice(&[*px, *px, *px]);
            }
            (
                scale_packed(&rgb, src_w, src_h, 3, 3, dst_w, dst_h),
                dst_w,
                dst_h,
                KittyFormat::Rgb,
            )
        }
        other => {
            let rgba = other.to_rgba8();
            let opaque = rgba.pixels().all(|px| px.0[3] == 255);
            let dst_ch = if opaque { 3 } else { 4 };
            let format = if opaque {
                KittyFormat::Rgb
            } else {
                KittyFormat::Rgba
            };
            (
                scale_packed(rgba.as_raw(), src_w, src_h, 4, dst_ch, dst_w, dst_h),
                dst_w,
                dst_h,
                format,
            )
        }
    }
}

/// 2x2 sample, matching Zig `resizeChannels`. One output pixel reads four source pixels.
fn scale_packed(
    src: &[u8],
    src_w: u32,
    src_h: u32,
    src_ch: usize,
    dst_ch: usize,
    new_w: u32,
    new_h: u32,
) -> Vec<u8> {
    if new_w == src_w && new_h == src_h {
        if src_ch == dst_ch {
            return src.to_vec();
        }
        return pack_channels(src, src_ch, dst_ch);
    }
    if src_w == 0 || src_h == 0 || new_w == 0 || new_h == 0 {
        return Vec::new();
    }
    let src_w = src_w as usize;
    let src_h = src_h as usize;
    let new_w_us = new_w as usize;
    let new_h_us = new_h as usize;
    let img_w = src_w as f32;
    let img_h = src_h as f32;
    let new_w_f = new_w as f32;
    let new_h_f = new_h as f32;
    let mut out = vec![0u8; new_w_us * new_h_us * dst_ch];
    for y in 0..new_h_us {
        let sy = y as f32 * img_h / new_h_f;
        let y0 = sy.floor() as usize;
        let y1 = (y0 + 1).min(src_h - 1);
        let dy = sy - sy.floor();
        for x in 0..new_w_us {
            let sx = x as f32 * img_w / new_w_f;
            let x0 = sx.floor() as usize;
            let x1 = (x0 + 1).min(src_w - 1);
            let dx = sx - sx.floor();
            let p00 = (y0 * src_w + x0) * src_ch;
            let p01 = (y0 * src_w + x1) * src_ch;
            let p10 = (y1 * src_w + x0) * src_ch;
            let p11 = (y1 * src_w + x1) * src_ch;
            let dst = (y * new_w_us + x) * dst_ch;
            for c in 0..dst_ch {
                out[dst + c] = lerp8(
                    src[p00 + c],
                    src[p01 + c],
                    src[p10 + c],
                    src[p11 + c],
                    dx,
                    dy,
                );
            }
        }
    }
    out
}

fn pack_channels(src: &[u8], src_ch: usize, dst_ch: usize) -> Vec<u8> {
    let pixels = src.len() / src_ch;
    let mut out = Vec::with_capacity(pixels * dst_ch);
    for px in src.chunks_exact(src_ch) {
        out.extend_from_slice(&px[..dst_ch]);
    }
    out
}

fn lerp8(v00: u8, v01: u8, v10: u8, v11: u8, dx: f32, dy: f32) -> u8 {
    let value = (1.0 - dx) * (1.0 - dy) * v00 as f32
        + dx * (1.0 - dy) * v01 as f32
        + (1.0 - dx) * dy * v10 as f32
        + dx * dy * v11 as f32;
    value.round() as u8
}

struct Anim {
    width: u32,
    height: u32,
    frames: Vec<Frame>,
    loops: u32,
}

#[derive(Clone, Copy)]
struct Placed {
    width: u32,
    height: u32,
    shrink: bool,
}

fn decode_animated(bytes: &[u8]) -> Option<Anim> {
    match image::guess_format(bytes).ok()? {
        ImageFormat::Gif => decode_gif(bytes),
        ImageFormat::WebP => decode_webp(bytes),
        ImageFormat::Png => decode_apng(bytes),
        _ => None,
    }
}

fn render_frames(anim: Anim, out: &mut impl Write) -> io::Result<()> {
    let (fit_w, fit_h) = fit_to_window(anim.width, anim.height);
    write!(out, "\n     ")?;
    let use_shm = crate::shm::shm_ready();
    let placed = placed_size(anim.width, anim.height, fit_w, fit_h);
    if anim.frames.len() > 1 && animation_fits(placed.width, placed.height, anim.frames.len()) {
        transmit_animation(&anim, placed, out, use_shm)?;
    } else if let Some(frame) = anim.frames.into_iter().next() {
        let img = DynamicImage::ImageRgba8(frame.into_buffer());
        transmit_still(&img, out, fit_w, fit_h, use_shm)?;
    }
    write!(out, "\n\n")?;
    out.flush()?;
    Ok(())
}

fn decode_gif(bytes: &[u8]) -> Option<Anim> {
    let decoder = GifDecoder::new(Cursor::new(bytes)).ok()?;
    let (width, height) = decoder.dimensions();
    let loops = kitty_loops(decoder.loop_count());
    // Stop at the first bad block. Frames already read stay.
    let mut frames = Vec::new();
    for frame in decoder.into_frames() {
        match frame {
            Ok(frame) => frames.push(frame),
            Err(_) => break,
        }
    }
    if frames.is_empty() {
        return None;
    }
    Some(Anim {
        width,
        height,
        frames,
        loops,
    })
}

fn decode_webp(bytes: &[u8]) -> Option<Anim> {
    let decoder = WebPDecoder::new(Cursor::new(bytes)).ok()?;
    if decoder.has_animation() {
        let (width, height) = decoder.dimensions();
        return collect_anim(decoder, width, height, 1);
    }
    let (width, height) = decoder.dimensions();
    let color = decoder.color_type();
    let nbytes = usize::try_from(decoder.total_bytes()).ok()?;
    let mut raw = vec![0u8; nbytes];
    decoder.read_image(&mut raw).ok()?;
    let rgba = match color {
        image::ColorType::Rgba8 => image::RgbaImage::from_raw(width, height, raw)?,
        image::ColorType::Rgb8 => {
            let rgb = image::RgbImage::from_raw(width, height, raw)?;
            DynamicImage::ImageRgb8(rgb).to_rgba8()
        }
        _ => return None,
    };
    let frame = Frame::from_parts(rgba, 0, 0, image::Delay::from_numer_denom_ms(0, 1));
    Some(Anim {
        width,
        height,
        frames: vec![frame],
        loops: 1,
    })
}

fn decode_apng(bytes: &[u8]) -> Option<Anim> {
    let decoder = PngDecoder::new(Cursor::new(bytes)).ok()?;
    if !decoder.is_apng().ok()? {
        return None;
    }
    let (width, height) = decoder.dimensions();
    collect_anim(decoder.apng().ok()?, width, height, 1)
}

fn collect_anim<'a, D>(decoder: D, width: u32, height: u32, min_frames: usize) -> Option<Anim>
where
    D: AnimationDecoder<'a>,
{
    let loops = kitty_loops(decoder.loop_count());
    let frames = decoder.into_frames().collect_frames().ok()?;
    if frames.len() < min_frames {
        return None;
    }
    Some(Anim {
        width,
        height,
        frames,
        loops,
    })
}

fn placed_size(src_w: u32, src_h: u32, fit_w: u32, fit_h: u32) -> Placed {
    let shrink = fit_w < src_w || fit_h < src_h;
    if shrink {
        Placed {
            width: fit_w,
            height: fit_h,
            shrink: true,
        }
    } else {
        Placed {
            width: src_w,
            height: src_h,
            shrink: false,
        }
    }
}

fn animation_fits(width: u32, height: u32, frame_count: usize) -> bool {
    const CAP: usize = 320 << 20;
    if frame_count < 2 || width == 0 || height == 0 {
        return false;
    }
    let Some(pixels) = (width as usize).checked_mul(height as usize) else {
        return false;
    };
    let Some(frame_bytes) = pixels.checked_mul(4) else {
        return false;
    };
    if frame_bytes == 0 {
        return false;
    }
    frame_count <= CAP / frame_bytes
}

/// Kitty treats a gap of 0 as unset. A non-positive duration is shown for 100 ms.
pub fn gap_ms(duration_s: f32) -> u32 {
    if !(duration_s > 0.0) {
        return 100;
    }
    let ms = (duration_s * 1000.0).round();
    if ms < 1.0 {
        return 1;
    }
    if ms > u32::MAX as f32 {
        return u32::MAX;
    }
    ms as u32
}

fn gap_from_delay(delay: image::Delay) -> u32 {
    let (numer, denom) = delay.numer_denom_ms();
    if denom == 0 {
        return 100;
    }
    gap_ms(numer as f32 / denom as f32 / 1000.0)
}

fn kitty_loops(count: LoopCount) -> u32 {
    match count {
        LoopCount::Infinite => 1,
        LoopCount::Finite(n) => n.get().saturating_add(1),
    }
}

fn transmit_animation(
    anim: &Anim,
    placed: Placed,
    out: &mut impl Write,
    use_shm: bool,
) -> io::Result<()> {
    let prepared = prepare_frames(&anim.frames, placed)?;
    if prepared.is_empty() {
        return Ok(());
    }
    let image_number = random_image_id();
    write_animation(
        out,
        &prepared,
        placed.width,
        placed.height,
        image_number,
        anim.loops,
        use_shm,
    )
}

struct PreparedFrame {
    bytes: Vec<u8>,
    gap_ms: u32,
}

fn prepare_frames(frames: &[Frame], placed: Placed) -> io::Result<Vec<PreparedFrame>> {
    if placed.shrink && (placed.width == 0 || placed.height == 0) {
        return Ok(Vec::new());
    }
    let needs_alpha = frames
        .iter()
        .any(|frame| frame.buffer().pixels().any(|px| px.0[3] != 255));
    let dst_ch = if needs_alpha { 4 } else { 3 };
    let mut prepared = Vec::with_capacity(frames.len());
    for frame in frames {
        let buf = frame.buffer();
        let (dst_w, dst_h) = if placed.shrink {
            (placed.width, placed.height)
        } else {
            (buf.width(), buf.height())
        };
        prepared.push(PreparedFrame {
            bytes: scale_packed(
                buf.as_raw(),
                buf.width(),
                buf.height(),
                4,
                dst_ch,
                dst_w,
                dst_h,
            ),
            gap_ms: gap_from_delay(frame.delay()),
        });
    }
    Ok(prepared)
}

fn write_animation(
    out: &mut impl Write,
    frames: &[PreparedFrame],
    width: u32,
    height: u32,
    image_number: u32,
    loops: u32,
    use_shm: bool,
) -> io::Result<()> {
    let format = if frames[0].bytes.len() == (width as usize) * (height as usize) * 4 {
        KittyFormat::Rgba
    } else {
        KittyFormat::Rgb
    };
    for (index, frame) in frames.iter().enumerate() {
        let gap = if index == 0 { None } else { Some(frame.gap_ms) };
        let mut sent = false;
        if use_shm {
            match crate::shm::transmit_frame_shm(
                out,
                &frame.bytes,
                width,
                height,
                image_number,
                gap,
                format,
            )? {
                crate::shm::ShmSend::Sent => sent = true,
                crate::shm::ShmSend::LocalFail => {}
            }
        }
        if !sent {
            let compressed = kitty::zlib_compress(&frame.bytes)?;
            kitty::write_frame_direct(out, &compressed, width, height, image_number, gap, format)?;
        }
        if index == 0 {
            write!(
                out,
                "\x1b_Ga=a,I={image_number},r=1,z={},v={loops},q=2;\x1b\\",
                frame.gap_ms
            )?;
        } else if index == 1 {
            write!(out, "\x1b_Ga=a,I={image_number},s=2,q=2;\x1b\\")?;
        }
    }
    write!(out, "\x1b_Ga=a,I={image_number},s=3,q=2;\x1b\\")?;
    Ok(())
}

fn random_image_id() -> u32 {
    let mut buf = [0u8; 4];
    if let Ok(mut file) = File::open("/dev/urandom") {
        if file.read_exact(&mut buf).is_ok() {
            let id = u32::from_le_bytes(buf);
            if id != 0 {
                return id;
            }
        }
    }
    1
}

fn fit_to_window(width: u32, height: u32) -> (u32, u32) {
    let mut ws_col: u16 = 80;
    let mut ws_row: u16 = 24;
    let mut ws_xpixel: u16 = 10 * ws_col;
    let mut ws_ypixel: u16 = 20 * ws_row;
    if let Ok(ws) = rustix::termios::tcgetwinsize(std::io::stdout()) {
        ws_col = ws.ws_col;
        ws_row = ws.ws_row;
        ws_xpixel = ws.ws_xpixel;
        ws_ypixel = ws.ws_ypixel;
    }
    let max_w = (ws_xpixel - (ws_xpixel / ws_col) * 6) as f32;
    let max_h = (ws_ypixel - (ws_ypixel / ws_row) * 3) as f32;
    let img_w = width as f32;
    let img_h = height as f32;
    let scale = (max_w / img_w).min(max_h / img_h);
    ((scale * img_w) as u32, (scale * img_h) as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use flate2::read::ZlibDecoder;
    use image::{ImageBuffer, Rgb, RgbImage, Rgba, RgbaImage};

    const NO_SHRINK: (u32, u32) = (4000, 4000);

    fn inflate_payloads(text: &str) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let mut rest = text;
        while let Some(pos) = rest.find("\x1b_G") {
            rest = &rest[pos..];
            let Some(semi) = rest.find(';') else { break };
            let Some(end) = rest[semi..].find("\x1b\\") else {
                break;
            };
            let control = &rest[..semi];
            let encoded = &rest[semi + 1..semi + end];
            rest = &rest[semi + end + 2..];
            if encoded.is_empty() || !control.contains("o=z") {
                continue;
            }
            let compressed = base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .unwrap();
            let mut dec = ZlibDecoder::new(&compressed[..]);
            let mut raw = Vec::new();
            std::io::Read::read_to_end(&mut dec, &mut raw).unwrap();
            out.push(raw);
        }
        out
    }

    #[test]
    fn guess_format_rejects_text() {
        assert!(is_image(b"\x89PNG\r\n\x1a\n"));
        assert!(is_image(b"\xff\xd8\xff"));
        assert!(is_image(b"GIF89a"));
        assert!(!is_image(b"hello \xff world\r\n"));
    }

    #[test]
    fn opaque_rgb_sends_f24() {
        let mut img = RgbImage::new(2, 2);
        let px = [
            Rgb([10, 20, 30]),
            Rgb([40, 50, 60]),
            Rgb([70, 80, 90]),
            Rgb([1, 2, 3]),
        ];
        for (i, p) in px.iter().enumerate() {
            img.put_pixel((i % 2) as u32, (i / 2) as u32, *p);
        }
        let mut out = Vec::new();
        transmit_still(
            &DynamicImage::ImageRgb8(img),
            &mut out,
            NO_SHRINK.0,
            NO_SHRINK.1,
            false,
        )
        .unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b_Gf=24,"));
        assert!(!text.contains("\x1b_Gf=32,"));
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads.len(), 1);
        assert_eq!(payloads[0], [10, 20, 30, 40, 50, 60, 70, 80, 90, 1, 2, 3]);
    }

    #[test]
    fn opaque_rgba_sends_f24() {
        let mut img = RgbaImage::new(2, 2);
        let px = [
            [10, 20, 30, 255],
            [40, 50, 60, 255],
            [70, 80, 90, 255],
            [1, 2, 3, 255],
        ];
        for (i, p) in px.iter().enumerate() {
            img.put_pixel((i % 2) as u32, (i / 2) as u32, Rgba(*p));
        }
        let mut out = Vec::new();
        transmit_still(
            &DynamicImage::ImageRgba8(img),
            &mut out,
            NO_SHRINK.0,
            NO_SHRINK.1,
            false,
        )
        .unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b_Gf=24,"));
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads[0], [10, 20, 30, 40, 50, 60, 70, 80, 90, 1, 2, 3]);
    }

    #[test]
    fn partial_alpha_sends_f32() {
        let mut img = RgbaImage::new(2, 2);
        for p in img.pixels_mut() {
            *p = Rgba([1, 2, 3, 255]);
        }
        img.get_pixel_mut(0, 0).0[3] = 0;
        img.get_pixel_mut(1, 1).0[3] = 128;
        let mut out = Vec::new();
        transmit_still(
            &DynamicImage::ImageRgba8(img),
            &mut out,
            NO_SHRINK.0,
            NO_SHRINK.1,
            false,
        )
        .unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b_Gf=32,"));
        assert!(!text.contains("\x1b_Gf=24,"));
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads[0].len(), 16);
        assert_eq!(payloads[0][3], 0);
        assert_eq!(payloads[0][15], 128);
    }

    #[test]
    fn grayscale_sends_f24() {
        let img = ImageBuffer::from_pixel(1, 1, image::Luma([40u8]));
        let mut out = Vec::new();
        transmit_still(
            &DynamicImage::ImageLuma8(img),
            &mut out,
            NO_SHRINK.0,
            NO_SHRINK.1,
            false,
        )
        .unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b_Gf=24,"));
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads[0], [40, 40, 40]);
    }

    #[test]
    fn resized_opaque_stays_flat() {
        let img = ImageBuffer::from_pixel(4, 4, Rgb([11, 22, 33]));
        let mut out = Vec::new();
        transmit_still(&DynamicImage::ImageRgb8(img), &mut out, 2, 2, false).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("\x1b_Gf=24,"));
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads[0].len(), 12);
        assert_eq!(&payloads[0][..3], &[11, 22, 33]);
    }

    #[test]
    fn gap_loop_place_and_cap() {
        use std::num::NonZeroU32;
        assert_eq!(gap_ms(0.0), 100);
        assert_eq!(gap_ms(-1.0), 100);
        assert_eq!(gap_ms(0.04), 40);
        assert_eq!(gap_ms(0.05), 50);
        assert_eq!(kitty_loops(LoopCount::Infinite), 1);
        assert_eq!(
            kitty_loops(LoopCount::Finite(NonZeroU32::new(3).unwrap())),
            4
        );
        let native = placed_size(200, 150, 560, 420);
        assert!(!native.shrink);
        assert_eq!((native.width, native.height), (200, 150));
        let shrunk = placed_size(800, 600, 400, 300);
        assert!(shrunk.shrink);
        assert_eq!((shrunk.width, shrunk.height), (400, 300));
        assert!(animation_fits(800, 335, 115));
        assert!(!animation_fits(800, 335, 400));
        assert!(!animation_fits(0, 10, 2));
        assert!(!animation_fits(10, 10, 1));
    }

    fn solid(w: u32, h: u32, px: [u8; 4]) -> RgbaImage {
        ImageBuffer::from_pixel(w, h, Rgba(px))
    }

    #[test]
    fn opaque_animation_sends_f24() {
        use image::{Delay, Frame};
        let anim = Anim {
            width: 2,
            height: 2,
            loops: 1,
            frames: vec![
                Frame::from_parts(
                    solid(2, 2, [5, 6, 7, 255]),
                    0,
                    0,
                    Delay::from_numer_denom_ms(40, 1),
                ),
                Frame::from_parts(
                    solid(2, 2, [8, 9, 10, 255]),
                    0,
                    0,
                    Delay::from_numer_denom_ms(40, 1),
                ),
            ],
        };
        let mut out = Vec::new();
        transmit_animation(&anim, placed_size(2, 2, 4000, 4000), &mut out, false).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text.matches("\x1b_Gf=24,").count(), 2);
        assert_eq!(text.matches("\x1b_Gf=32,").count(), 0);
        assert!(text.contains(",v=1,q=2;"));
        assert!(text.contains("z=40"));
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads.len(), 2);
        assert_eq!(&payloads[0][..3], &[5, 6, 7]);
        assert_eq!(&payloads[1][..3], &[8, 9, 10]);
        assert_eq!(payloads[0].len(), 12);
    }

    #[test]
    fn transparent_frame_sends_f32() {
        use image::{Delay, Frame};
        let anim = Anim {
            width: 2,
            height: 2,
            loops: 4,
            frames: vec![
                Frame::from_parts(
                    solid(2, 2, [1, 2, 3, 255]),
                    0,
                    0,
                    Delay::from_numer_denom_ms(40, 1),
                ),
                Frame::from_parts(
                    solid(2, 2, [4, 5, 6, 0]),
                    0,
                    0,
                    Delay::from_numer_denom_ms(40, 1),
                ),
            ],
        };
        let mut out = Vec::new();
        transmit_animation(&anim, placed_size(2, 2, 4000, 4000), &mut out, false).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text.matches("\x1b_Gf=32,").count(), 2);
        assert_eq!(text.matches("\x1b_Gf=24,").count(), 0);
        let payloads = inflate_payloads(&text);
        assert_eq!(payloads[0].len(), 16);
        assert_eq!(payloads[1].len(), 16);
        assert_eq!(payloads[0][3], 255);
        assert_eq!(payloads[1][3], 0);
        assert_eq!(payloads[1][0], 4);
    }

    fn two_frame_gif_bytes() -> Vec<u8> {
        use image::codecs::gif::{GifEncoder, Repeat};
        use image::{Delay, Frame};
        let mut bytes = Vec::new();
        let mut enc = GifEncoder::new(std::io::Cursor::new(&mut bytes));
        enc.set_repeat(Repeat::Infinite).unwrap();
        enc.encode_frame(Frame::from_parts(
            solid(2, 2, [255, 0, 0, 255]),
            0,
            0,
            Delay::from_numer_denom_ms(40, 1),
        ))
        .unwrap();
        enc.encode_frame(Frame::from_parts(
            solid(2, 2, [0, 0, 255, 255]),
            0,
            0,
            Delay::from_numer_denom_ms(40, 1),
        ))
        .unwrap();
        drop(enc);
        bytes
    }

    fn second_image_offset(bytes: &[u8]) -> usize {
        let mut i = 13usize;
        if bytes[10] & 0x80 != 0 {
            i += 3 * (1usize << ((bytes[10] & 7) + 1));
        }
        let mut images = 0usize;
        while i < bytes.len() {
            match bytes[i] {
                0x3b => break,
                0x21 => {
                    i += 2;
                    while i < bytes.len() {
                        let n = bytes[i] as usize;
                        i += 1;
                        if n == 0 {
                            break;
                        }
                        i += n;
                    }
                }
                0x2c => {
                    images += 1;
                    if images == 2 {
                        return i;
                    }
                    i += 10;
                    let flags = bytes[i - 1];
                    if flags & 0x80 != 0 {
                        i += 3 * (1usize << ((flags & 7) + 1));
                    }
                    i += 1;
                    while i < bytes.len() {
                        let n = bytes[i] as usize;
                        i += 1;
                        if n == 0 {
                            break;
                        }
                        i += n;
                    }
                }
                _ => break,
            }
        }
        panic!("gif has no second image");
    }

    #[test]
    fn two_frame_gif() {
        let anim = decode_gif(&two_frame_gif_bytes()).expect("gif animation");
        assert_eq!((anim.width, anim.height), (2, 2));
        assert_eq!(anim.frames.len(), 2);
        assert_eq!(anim.loops, 1);
        assert_eq!(gap_from_delay(anim.frames[0].delay()), 40);
        assert_eq!(gap_from_delay(anim.frames[1].delay()), 40);
    }

    #[test]
    fn gif_trailing_nul_keeps_frames() {
        let mut bytes = two_frame_gif_bytes();
        assert_eq!(bytes.last().copied(), Some(0x3b));
        bytes.insert(bytes.len() - 1, 0);
        let anim = decode_gif(&bytes).expect("frames before the bad block");
        assert_eq!(anim.frames.len(), 2);
        assert_eq!(anim.frames[0].buffer().get_pixel(0, 0).0, [255, 0, 0, 255]);
        assert_eq!(anim.frames[1].buffer().get_pixel(0, 0).0, [0, 0, 255, 255]);
    }

    #[test]
    fn gif_truncated_later_frame_keeps_earlier_frames() {
        let bytes = two_frame_gif_bytes();
        let cut = second_image_offset(&bytes);
        let anim = decode_gif(&bytes[..cut]).expect("first frame");
        assert_eq!(anim.frames.len(), 1);
        assert_eq!(anim.frames[0].buffer().get_pixel(0, 0).0, [255, 0, 0, 255]);
    }

    #[test]
    fn still_png_skips_animation() {
        let mut buf = std::io::Cursor::new(Vec::new());
        let img = RgbaImage::from_pixel(1, 1, Rgba([1, 2, 3, 255]));
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut buf, image::ImageFormat::Png)
            .unwrap();
        assert!(decode_apng(buf.get_ref()).is_none());
        assert!(decode_animated(buf.get_ref()).is_none());
    }

    #[test]
    fn still_webp_is_one_frame() {
        let mut buf = std::io::Cursor::new(Vec::new());
        let img = RgbaImage::from_pixel(2, 2, Rgba([9, 8, 7, 255]));
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut buf, image::ImageFormat::WebP)
            .unwrap();
        let anim = decode_webp(buf.get_ref()).expect("webp");
        assert_eq!(anim.frames.len(), 1);
        assert_eq!((anim.width, anim.height), (2, 2));
        assert_eq!(anim.frames[0].buffer().get_pixel(0, 0).0, [9, 8, 7, 255]);
    }
}
