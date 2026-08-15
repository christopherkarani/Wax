// @ts-check
const { themes: prismThemes } = require("prism-react-renderer");

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: "Wax",
  tagline: "On-device memory for Swift apps. One file. No servers.",
  favicon: "img/favicon.ico",
  url: "https://christopherkarani.github.io",
  baseUrl: "/Wax/",
  organizationName: "christopherkarani",
  projectName: "Wax",
  onBrokenLinks: "throw",

  markdown: {
    hooks: {
      onBrokenMarkdownLinks: "warn",
    },
  },

  i18n: {
    defaultLocale: "en",
    locales: ["en"],
  },

  stylesheets: [
    {
      href: "https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600;700&display=swap",
      type: "text/css",
    },
  ],

  presets: [
    [
      "classic",
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          sidebarPath: "./sidebars.js",
          editUrl:
            "https://github.com/christopherkarani/Wax/tree/main/Resources/website/",
        },
        blog: false,
        theme: {
          customCss: "./src/css/custom.css",
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      colorMode: {
        defaultMode: "dark",
        disableSwitch: true,
        respectPrefersColorScheme: false,
      },
      navbar: {
        title: "Wax",
        items: [
          {
            type: "docSidebar",
            sidebarId: "docs",
            position: "left",
            label: "Docs",
          },
          {
            label: "iOS docs →",
            href: "/docs/ios/getting-started",
            position: "right",
          },
          {
            href: "https://github.com/christopherkarani/Wax",
            label: "GitHub",
            position: "right",
          },
        ],
      },
      footer: {
        style: "dark",
        links: [
          {
            title: "Docs",
            items: [
              { label: "Overview", to: "/docs/intro" },
              { label: "iOS get started", to: "/docs/ios/getting-started" },
              {
                label: "Foundation Models",
                to: "/docs/ios/foundation-models",
              },
            ],
          },
          {
            title: "Community",
            items: [
              {
                label: "GitHub",
                href: "https://github.com/christopherkarani/Wax",
              },
              {
                label: "Issues",
                href: "https://github.com/christopherkarani/Wax/issues",
              },
            ],
          },
        ],
        copyright: `Copyright © ${new Date().getFullYear()} Christopher Karani. Built with Docusaurus.`,
      },
      prism: {
        theme: prismThemes.vsDark,
        darkTheme: prismThemes.vsDark,
        additionalLanguages: ["swift", "bash"],
      },
    }),
};

module.exports = config;
