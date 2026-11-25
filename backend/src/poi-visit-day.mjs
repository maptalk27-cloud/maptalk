import tzLookup from '@photostructure/tz-lookup';

export const POI_VISIT_DAY_POLICY = 'place-iana-v1';
const zones = new Map();
const formatters = new Map();

// Offline geographic lookup selects the place's IANA zone; Intl applies its
// historical civil offset/DST. This is not a viewer or longitude/solar day.
// The small compressed boundary dataset is approximate near zone borders.
export function poiVisitDay(timestamp, latitude, longitude) {
  const key = `${latitude},${longitude}`;
  let zone = zones.get(key);
  if (!zone) {
    zone = tzLookup(latitude, longitude);
    if (zones.size >= 1024) zones.clear();
    zones.set(key, zone);
  }
  let formatter = formatters.get(zone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat('en-US', {
      timeZone: zone, calendar: 'gregory', numberingSystem: 'latn',
      year: 'numeric', month: '2-digit', day: '2-digit',
    });
    formatters.set(zone, formatter);
  }
  const parts = Object.fromEntries(formatter.formatToParts(new Date(timestamp)).map(part => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
