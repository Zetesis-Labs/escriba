import { createContext, useContext } from "react";
import { macOS, type Platform } from "../core/platform";

export const PlatformContext = createContext<Platform>(macOS);
export const usePlatform = () => useContext(PlatformContext);
