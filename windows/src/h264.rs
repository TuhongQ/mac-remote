//! H.264 编码（OpenH264 软件编码），输出和 Mac 版一样的格式，网页直接用 WebCodecs 解码：
//!   类型 1 = 解码配置：宽、高各 2 字节（大端）+ avcC
//!   类型 2 = 关键帧，类型 3 = 普通帧：AVCC 格式（每个 NAL 前面 4 字节长度）
//! 不依赖 Windows API，可以在 Mac 上单独测试。

use openh264::encoder::{
    BitRate, Complexity, Encoder, EncoderConfig, FrameRate, IntraFramePeriod, Profile, RateControlMode, UsageType,
    VuiConfig,
};
use openh264::formats::{BgraSliceU8, YUVBuffer};
use openh264::OpenH264API;

pub struct H264 {
    enc: Encoder,
    yuv: YUVBuffer,
    pub width: usize,
    pub height: usize,
    avcc: Vec<u8>,
    force_key: bool,
}

/// 编出来的一条消息（第一个字节就是类型）
pub type Packet = Vec<u8>;

impl H264 {
    /// width、height 要是偶数
    pub fn new(width: usize, height: usize, fps: u32) -> Result<H264, String> {
        // 码率和 Mac 版一样按像素数算：1920×1080×30 帧 ≈ 7.5 Mbps
        let bps = ((width * height) as f64 * fps as f64 * 0.12).clamp(2_000_000.0, 25_000_000.0) as u32;
        let cfg = EncoderConfig::new()
            .usage_type(UsageType::ScreenContentRealTime)
            .profile(Profile::Baseline)
            .complexity(Complexity::Low)
            .rate_control_mode(RateControlMode::Bitrate)
            .bitrate(BitRate::from_bps(bps))
            .max_frame_rate(FrameRate::from_hz(fps as f32))
            .skip_frames(false)
            .adaptive_quantization(false)
            .background_detection(false)
            .intra_frame_period(IntraFramePeriod::from_num_frames(0))
            .vui(VuiConfig::bt601());
        let enc = Encoder::with_api_config(OpenH264API::from_source(), cfg).map_err(|e| format!("{e}"))?;
        Ok(H264 { enc, yuv: YUVBuffer::new(width, height), width, height, avcc: Vec::new(), force_key: true })
    }

    pub fn force_key(&mut self) {
        self.force_key = true;
    }

    /// 编码一帧 BGRA（宽高必须等于编码器的宽高）。返回要发给手机的消息：可能先有一条配置，再有一帧
    pub fn encode(&mut self, bgra: &[u8]) -> Result<Vec<Packet>, String> {
        self.yuv.read_bgra8(BgraSliceU8::new(bgra, (self.width, self.height)));
        if self.force_key {
            self.enc.force_intra_frame();
            self.force_key = false;
        }
        let annexb = self.enc.encode(&self.yuv).map_err(|e| format!("{e}"))?.to_vec();
        let mut out = Vec::new();
        let (mut sps, mut pps) = (None, None);
        let mut frame = Vec::with_capacity(annexb.len() + 16);
        frame.push(3u8);
        let mut key = false;
        for nal in split_annexb(&annexb) {
            if nal.is_empty() {
                continue;
            }
            match nal[0] & 0x1F {
                7 => sps = Some(nal),
                8 => pps = Some(nal),
                9 => {} // 访问单元分隔符，不要
                t => {
                    if t == 5 {
                        key = true;
                    }
                    frame.extend_from_slice(&(nal.len() as u32).to_be_bytes());
                    frame.extend_from_slice(nal);
                }
            }
        }
        if let (Some(sps), Some(pps)) = (sps, pps) {
            if sps.len() >= 4 {
                let mut avcc = vec![1, sps[1], sps[2], sps[3], 0xFF, 0xE1];
                avcc.extend_from_slice(&(sps.len() as u16).to_be_bytes());
                avcc.extend_from_slice(sps);
                avcc.push(1);
                avcc.extend_from_slice(&(pps.len() as u16).to_be_bytes());
                avcc.extend_from_slice(pps);
                if avcc != self.avcc {
                    let mut cfg = vec![1u8];
                    cfg.extend_from_slice(&(self.width as u16).to_be_bytes());
                    cfg.extend_from_slice(&(self.height as u16).to_be_bytes());
                    cfg.extend_from_slice(&avcc);
                    out.push(cfg);
                    self.avcc = avcc;
                }
            }
        }
        if frame.len() > 1 {
            if key {
                frame[0] = 2;
            }
            out.push(frame);
        }
        Ok(out)
    }

    /// avc1.PPCCLL，日志用
    pub fn codec_string(&self) -> String {
        if self.avcc.len() < 4 {
            return "?".into();
        }
        format!("avc1.{:02x}{:02x}{:02x}", self.avcc[1], self.avcc[2], self.avcc[3])
    }
}

/// 按起始码 00 00 01 / 00 00 00 01 切出 NAL
fn split_annexb(b: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new(); // (起始码开始位置, NAL 开始位置)
    let mut i = 0;
    while i + 3 <= b.len() {
        if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
            let s = if i > 0 && b[i - 1] == 0 { i - 1 } else { i };
            starts.push((s, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::new();
    for (k, &(_, nal_at)) in starts.iter().enumerate() {
        let end = starts.get(k + 1).map(|x| x.0).unwrap_or(b.len());
        if end > nal_at {
            out.push(&b[nal_at..end]);
        }
    }
    out
}
