use chrono::{DateTime, Datelike, Duration, TimeZone, Utc};

use crate::model::{DisplayMode, WindowKind};

pub fn comparison_range(
    mode: &DisplayMode,
    now: DateTime<Utc>,
) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
    match mode {
        DisplayMode::ProviderCycles => None,
        DisplayMode::FiveHours => Some((now - Duration::hours(5), now)),
        DisplayMode::OneWeek => {
            let date = now.date_naive();
            let monday = date - Duration::days(date.weekday().num_days_from_monday().into());
            let start = Utc
                .with_ymd_and_hms(monday.year(), monday.month(), monday.day(), 0, 0, 0)
                .single()
                .expect("valid ISO week start");
            Some((start, start + Duration::days(7)))
        }
        DisplayMode::OneMonth => {
            let date = now.date_naive();
            let start = Utc
                .with_ymd_and_hms(date.year(), date.month(), 1, 0, 0, 0)
                .single()
                .expect("valid month start");
            let (next_year, next_month) = if date.month() == 12 {
                (date.year() + 1, 1)
            } else {
                (date.year(), date.month() + 1)
            };
            let end = Utc
                .with_ymd_and_hms(next_year, next_month, 1, 0, 0, 0)
                .single()
                .expect("valid next month start");
            Some((start, end))
        }
    }
}

pub fn infer_window_kind_from_minutes(minutes: i64) -> WindowKind {
    match minutes {
        300 => WindowKind::FiveHours,
        10_080 => WindowKind::OneWeek,
        40_320..=44_640 => WindowKind::OneMonth,
        other => WindowKind::CustomMinutes(other),
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};

    use crate::model::{DisplayMode, WindowKind};

    use super::{comparison_range, infer_window_kind_from_minutes};

    #[test]
    fn five_hour_range_is_rolling() {
        let now = Utc.with_ymd_and_hms(2026, 6, 1, 12, 0, 0).single().unwrap();
        let (start, end) = comparison_range(&DisplayMode::FiveHours, now).unwrap();
        assert_eq!(
            start,
            Utc.with_ymd_and_hms(2026, 6, 1, 7, 0, 0).single().unwrap()
        );
        assert_eq!(end, now);
    }

    #[test]
    fn week_range_starts_on_monday_utc() {
        let now = Utc.with_ymd_and_hms(2026, 6, 3, 12, 0, 0).single().unwrap();
        let (start, end) = comparison_range(&DisplayMode::OneWeek, now).unwrap();
        assert_eq!(
            start,
            Utc.with_ymd_and_hms(2026, 6, 1, 0, 0, 0).single().unwrap()
        );
        assert_eq!(
            end,
            Utc.with_ymd_and_hms(2026, 6, 8, 0, 0, 0).single().unwrap()
        );
    }

    #[test]
    fn month_range_uses_calendar_month_utc() {
        let now = Utc
            .with_ymd_and_hms(2026, 12, 31, 12, 0, 0)
            .single()
            .unwrap();
        let (start, end) = comparison_range(&DisplayMode::OneMonth, now).unwrap();
        assert_eq!(
            start,
            Utc.with_ymd_and_hms(2026, 12, 1, 0, 0, 0).single().unwrap()
        );
        assert_eq!(
            end,
            Utc.with_ymd_and_hms(2027, 1, 1, 0, 0, 0).single().unwrap()
        );
    }

    #[test]
    fn maps_known_provider_window_minutes() {
        assert_eq!(infer_window_kind_from_minutes(300), WindowKind::FiveHours);
        assert_eq!(infer_window_kind_from_minutes(10_080), WindowKind::OneWeek);
        assert_eq!(infer_window_kind_from_minutes(43_200), WindowKind::OneMonth);
        assert_eq!(
            infer_window_kind_from_minutes(42),
            WindowKind::CustomMinutes(42)
        );
    }
}
