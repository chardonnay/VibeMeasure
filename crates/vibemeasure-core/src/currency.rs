use chrono::{DateTime, Utc};
use quick_xml::{Reader, XmlVersion, events::Event};

use crate::{
    Result, VibeError,
    model::{CurrencyRate, SourceKind, SourceMeta, SourceStatus},
};

pub const ECB_DAILY_RATES_URL: &str =
    "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml";

pub fn fetch_ecb_daily_rates() -> Result<Vec<CurrencyRate>> {
    let mut response = ureq::get(ECB_DAILY_RATES_URL)
        .header("User-Agent", "VibeMeasure/0.1")
        .call()
        .map_err(|error| VibeError::Http(error.to_string()))?;
    let body = response
        .body_mut()
        .read_to_string()
        .map_err(|error| VibeError::Http(error.to_string()))?;
    parse_ecb_daily_rates(&body, Utc::now())
}

pub fn parse_ecb_daily_rates(xml: &str, fetched_at: DateTime<Utc>) -> Result<Vec<CurrencyRate>> {
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut rates = Vec::new();

    loop {
        match reader.read_event()? {
            Event::Empty(element) | Event::Start(element) if element.name().as_ref() == b"Cube" => {
                let mut currency = None;
                let mut rate = None;

                for attribute in element.attributes() {
                    let attribute = attribute.map_err(|error| VibeError::Xml(error.into()))?;
                    let value = attribute
                        .decoded_and_normalized_value(XmlVersion::Implicit1_0, element.decoder())
                        .map_err(VibeError::Xml)?
                        .to_string();
                    match attribute.key.as_ref() {
                        b"currency" => currency = Some(value),
                        b"rate" => {
                            rate = Some(value.parse::<f64>().map_err(|error| {
                                VibeError::InvalidData(format!("invalid ECB rate: {error}"))
                            })?)
                        }
                        _ => {}
                    }
                }

                if let (Some(currency), Some(rate)) = (currency, rate) {
                    rates.push(CurrencyRate {
                        base_currency: "EUR".to_string(),
                        quote_currency: currency,
                        rate,
                        source: SourceMeta {
                            kind: SourceKind::OfficialDocs,
                            status: SourceStatus::Verified,
                            label: "ECB euro foreign exchange reference rates".to_string(),
                            fetched_at,
                        },
                    });
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }

    Ok(rates)
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use super::parse_ecb_daily_rates;

    #[test]
    fn parses_ecb_reference_rate_xml() {
        let xml = r#"
        <gesmes:Envelope>
          <Cube>
            <Cube time="2026-06-01">
              <Cube currency="USD" rate="1.1234"/>
              <Cube currency="GBP" rate="0.8123"/>
            </Cube>
          </Cube>
        </gesmes:Envelope>
        "#;
        let rates = parse_ecb_daily_rates(
            xml,
            Utc.with_ymd_and_hms(2026, 6, 1, 12, 0, 0).single().unwrap(),
        )
        .unwrap();
        assert_eq!(rates.len(), 2);
        assert_eq!(rates[0].base_currency, "EUR");
        assert_eq!(rates[0].quote_currency, "USD");
        assert_eq!(rates[0].rate, 1.1234);
    }
}
