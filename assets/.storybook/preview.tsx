import type { Preview } from "@storybook/react-vite";
import { mswLoader } from "msw-storybook-addon/csf3";
import { handlers } from "../src/mocks/handlers";
import { setupI18n } from "../src/i18n";
import "../src/styles.css";

setupI18n("en");

const preview: Preview = {
  parameters: {
    layout: "fullscreen",
    msw: { handlers },
    backgrounds: { disable: true },
  },
  loaders: [mswLoader()],
};

export default preview;
