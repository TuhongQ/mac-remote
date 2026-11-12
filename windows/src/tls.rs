//! HTTPS 证书（视频模式要用：浏览器只允许 https 网页用 WebCodecs 解码视频）
//!
//! 和 Mac 版一样：第一次运行生成一个本机根证书（10 年），手机下载 /ca.cer 安装并信任一次；
//! 再用它给本机 IP 签发服务器证书（800 天，iOS 要求不超过 825 天）。IP 变了自动重新签发，手机不用重装。
//! 不依赖 Windows API，可以在 Mac 上单独测试。

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use rcgen::{
    date_time_ymd, BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose, SanType,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use rustls::ServerConfig;

/// 今天往前 / 往后 offset_days 天的年月日（UTC）
fn ymd(offset_days: i64) -> (i32, u8, u8) {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    // 公历换算（Howard Hinnant 的 civil_from_days）
    let z = now / 86400 + offset_days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u8;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u8;
    ((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

/// 证书文件都放在 dir 里。sans：服务器证书要包含的 IP / 主机名。返回 (根证书 DER, rustls 配置)
pub fn load_or_create(dir: &Path, ca_name: &str, sans: &[String]) -> Result<(Vec<u8>, Arc<ServerConfig>), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let f = |n: &str| dir.join(n);
    let at = |o: i64| {
        let (y, m, d) = ymd(o);
        date_time_ymd(y, m, d)
    };

    // 根证书
    let (ca_der, ca_key) = match (fs::read(f("ca.der")), fs::read_to_string(f("ca.key"))) {
        (Ok(der), Ok(pem)) if KeyPair::from_pem(&pem).is_ok() => (der, KeyPair::from_pem(&pem).unwrap()),
        _ => {
            let key = KeyPair::generate().map_err(|e| e.to_string())?;
            let mut p = CertificateParams::default();
            let mut dn = DistinguishedName::new();
            dn.push(DnType::CommonName, ca_name);
            dn.push(DnType::OrganizationName, "PC Remote Local");
            p.distinguished_name = dn;
            p.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
            p.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
            p.not_before = at(-1);
            p.not_after = at(3650);
            let cert = p.self_signed(&key).map_err(|e| e.to_string())?;
            fs::write(f("ca.der"), cert.der()).map_err(|e| e.to_string())?;
            fs::write(f("ca.key"), key.serialize_pem()).map_err(|e| e.to_string())?;
            let _ = fs::remove_file(f("server.sans"));
            (cert.der().to_vec(), key)
        }
    };

    // 服务器证书：SAN 变了（换了 IP）或者快过期就重新签
    let want = format!("v1|{}", sans.join(","));
    let fresh = fs::read_to_string(f("server.sans")).ok().as_deref() == Some(want.as_str())
        && fs::metadata(f("server.der"))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .map(|e| e.as_secs() < 700 * 86400)
            .unwrap_or(false);
    let (leaf_der, leaf_key_der) = match (fresh, fs::read(f("server.der")), fs::read_to_string(f("server.key"))) {
        (true, Ok(der), Ok(pem)) if KeyPair::from_pem(&pem).is_ok() => (der, KeyPair::from_pem(&pem).unwrap().serialize_der()),
        _ => {
            let issuer = Issuer::from_ca_cert_der(&CertificateDer::from(ca_der.clone()), &ca_key).map_err(|e| e.to_string())?;
            let key = KeyPair::generate().map_err(|e| e.to_string())?;
            let mut p = CertificateParams::default();
            let mut dn = DistinguishedName::new();
            dn.push(DnType::CommonName, "PC Remote");
            p.distinguished_name = dn;
            p.is_ca = IsCa::ExplicitNoCa;
            p.key_usages = vec![KeyUsagePurpose::DigitalSignature];
            p.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
            p.use_authority_key_identifier_extension = true;
            p.not_before = at(-1);
            p.not_after = at(800);
            for s in sans {
                if let Ok(ip) = s.parse() {
                    p.subject_alt_names.push(SanType::IpAddress(ip));
                } else if let Ok(n) = s.as_str().try_into() {
                    p.subject_alt_names.push(SanType::DnsName(n));
                }
            }
            let cert = p.signed_by(&key, &issuer).map_err(|e| e.to_string())?;
            fs::write(f("server.der"), cert.der()).map_err(|e| e.to_string())?;
            fs::write(f("server.key"), key.serialize_pem()).map_err(|e| e.to_string())?;
            fs::write(f("server.sans"), &want).map_err(|e| e.to_string())?;
            (cert.der().to_vec(), key.serialize_der())
        }
    };

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cfg = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_no_client_auth()
        .with_single_cert(
            vec![CertificateDer::from(leaf_der), CertificateDer::from(ca_der.clone())],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(leaf_key_der)),
        )
        .map_err(|e| e.to_string())?;
    Ok((ca_der, Arc::new(cfg)))
}
