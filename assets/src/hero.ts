import { heroui } from "@heroui/theme";

const purple = {
  50: "#f5edff",
  100: "#ece0ff",
  200: "#d9c2ff",
  300: "#c29dff",
  400: "#a66bff",
  500: "#8338ec",
  600: "#7025d5",
  700: "#5c1cb0",
  800: "#47158a",
  900: "#2f0e5c",
  DEFAULT: "#8338ec",
  foreground: "#ffffff",
};

export default heroui({
  themes: {
    light: {
      colors: {
        background: "#f4f4f5",
        foreground: "#0d0d12",
        focus: purple.DEFAULT,
        primary: purple,
        content1: "#ffffff",
      },
    },
    dark: {
      colors: {
        background: "#101014",
        foreground: "#f4f4f5",
        focus: purple[400],
        primary: { ...purple, DEFAULT: "#9a5cf0", foreground: "#ffffff" },
        content1: "#18181d",
      },
    },
  },
});
