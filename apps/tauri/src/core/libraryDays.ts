import { dateParts, dayLabel } from "./presentation";

export interface DayGroup<T> {
  key: string;
  heading: string;
  items: T[];
}

const two = (value: number) => String(value).padStart(2, "0");

export function dayKey(date: Date, timeZone?: string) {
  const parts = dateParts(date, timeZone);
  return `${parts.year}-${two(parts.month)}-${two(parts.day)}`;
}

export function groupByDay<T extends { createdAt: string }>(items: T[], now: Date, timeZone?: string): DayGroup<T>[] {
  const groups: DayGroup<T>[] = [];
  for (const item of items) {
    const date = new Date(item.createdAt);
    const key = dayKey(date, timeZone);
    const last = groups[groups.length - 1];
    if (last?.key === key) last.items.push(item);
    else groups.push({ key, heading: dayLabel(date, now, timeZone), items: [item] });
  }
  return groups;
}
