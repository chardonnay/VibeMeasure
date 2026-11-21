use std::fmt::Write;

const LINE_WIDTH: usize = 82;
const LINES_PER_PAGE: usize = 52;

// Use the built-in Courier font with a declared Windows-1252 encoding. Preserve
// unrepresentable characters as visible Unicode code points in evidence labels.
fn printable_bytes(line: &str) -> Vec<u8> {
    const WIN_EXT: &str = "€\u{fffd}‚ƒ„…†‡ˆ‰Š‹Œ\u{fffd}Ž\u{fffd}\u{fffd}‘’“”•–—˜™š›œ\u{fffd}žŸ";
    let mut bytes = Vec::new();
    for ch in line.chars() {
        if ch.is_whitespace() {
            bytes.push(b' ');
        } else if ch.is_ascii_graphic() || ('\u{a0}'..='ÿ').contains(&ch) {
            bytes.push(ch as u8);
        } else if !ch.is_control() {
            if let Some(index) = WIN_EXT.chars().position(|c| c == ch && c != '\u{fffd}') {
                bytes.push(0x80 + index as u8);
            } else {
                bytes.extend_from_slice(format!("[U+{:04X}]", ch as u32).as_bytes());
            }
        }
    }
    bytes
}

fn wrap_line(line: &str) -> Vec<Vec<u8>> {
    let bytes = printable_bytes(line);
    let mut rest = bytes.as_slice();
    let mut result = Vec::new();
    while rest.len() > LINE_WIDTH {
        let split = rest[..LINE_WIDTH]
            .iter()
            .rposition(|&byte| byte == b' ')
            .filter(|&pos| pos > 0)
            .unwrap_or(LINE_WIDTH);
        result.push(rest[..split].to_vec());
        rest = &rest[split..];
        rest = rest.strip_prefix(b" ").unwrap_or(rest);
    }
    result.push(rest.to_vec());
    result
}

fn page_content(lines: &[Vec<u8>]) -> String {
    let mut content = String::from("BT\n/F1 10 Tf\n48 790 Td\n14 TL\n");
    for line in lines {
        content.push('(');
        for &byte in line {
            match byte {
                b'\\' | b'(' | b')' => {
                    content.push('\\');
                    content.push(char::from(byte));
                }
                32..=126 => content.push(char::from(byte)),
                _ => write!(content, "\\{byte:03o}").unwrap(),
            }
        }
        content.push_str(") Tj\nT*\n");
    }
    content.push_str("ET\n");
    content
}

pub(super) fn document(lines: &[String]) -> Vec<u8> {
    let lines: Vec<_> = lines.iter().flat_map(|line| wrap_line(line)).collect();
    let mut objects = vec![
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        String::new(),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"
            .to_string(),
    ];
    let mut pages = Vec::new();
    for chunk in lines.chunks(LINES_PER_PAGE) {
        let page = objects.len() + 1;
        pages.push(format!("{page} 0 R"));
        objects.push(format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>",
            page + 1
        ));
        let content = page_content(chunk);
        objects.push(format!(
            "<< /Length {} >>\nstream\n{content}endstream",
            content.len()
        ));
    }
    objects[1] = format!(
        "<< /Type /Pages /Kids [{}] /Count {} >>",
        pages.join(" "),
        pages.len()
    );

    let mut pdf = String::from("%PDF-1.4\n");
    let mut offsets = Vec::with_capacity(objects.len());
    for (index, object) in objects.iter().enumerate() {
        offsets.push(pdf.len());
        writeln!(pdf, "{} 0 obj\n{object}\nendobj", index + 1).unwrap();
    }
    let xref_start = pdf.len();
    let size = offsets.len() + 1;
    writeln!(pdf, "xref\n0 {size}\n0000000000 65535 f ").unwrap();
    for offset in offsets {
        writeln!(pdf, "{offset:010} 00000 n ").unwrap();
    }
    writeln!(
        pdf,
        "trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref_start}\n%%EOF"
    )
    .unwrap();
    pdf.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_and_paginates_without_losing_source_notes() {
        let mut lines = vec!["Usage source: Test Quelle".to_string(); LINES_PER_PAGE];
        lines.push("Düsseldorf: (a) \\ ".repeat(20));
        let pdf = String::from_utf8(document(&lines)).unwrap();
        assert!(pdf.contains("/Count 2"));
        assert_eq!(pdf.matches("D\\374sseldorf:").count(), 20);
        assert!(pdf.contains("\\(a\\) \\\\"));
        assert!(
            wrap_line(&"x".repeat(10 * LINE_WIDTH))
                .iter()
                .all(|row| row.len() <= LINE_WIDTH)
        );
    }
}
