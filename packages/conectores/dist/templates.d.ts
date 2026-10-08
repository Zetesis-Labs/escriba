import type { Note } from "./types.js";
export declare const marker: RegExp;
export declare function render(text: string, value: (token: string) => string): string;
export declare function sole(text: string): string | undefined;
export declare function clock(seconds: number): string;
export declare function dateValues(iso: string, timeZone: string): {
    day: string;
    iso: string;
    long: string;
};
export declare function monthHeading(key: string): string;
export declare function turns(note: Note): {
    text: string;
    speaker?: string | null;
    start?: number;
}[];
export declare function prefix(turn: {
    speaker?: string | null;
    start?: number;
}, style: string): string;
export declare function transcript(note: Note, style?: string, markdown?: boolean): string;
export declare function values(note: Note): {
    title: string;
    tags: string[];
    speakers: string[];
    duration: number | undefined;
    date: {
        day: string;
        iso: string;
        long: string;
    };
    inline: (token: string) => string;
};
export declare function cleanBody(text: string): string;
export declare function slug(text: string): string;
export declare const quote: (text: string) => string;
export declare const linkText: (text: string) => string;
