# App Store support and marketing site

The existing public site in `docs/` is hosted independently of the deep-link
Worker at https://support.dtweet.com/.

App Store Connect URLs:

- Support URL: https://support.dtweet.com/#contact
- Marketing URL: https://support.dtweet.com/

Deploy from the repository root with an authenticated Cloudflare Wrangler CLI:

```sh
npx wrangler deploy --config cloudflare/support-site/wrangler.toml
```

`docs/.assetsignore` limits uploads to the four public site files. Internal
documentation is excluded. This deployment does not change the `dtweet.com`
deep-link Worker or its web fallback. The existing GitHub Pages site remains
available for links already submitted to Apple.

The original site's `privacy.html` and `terms.html` links have no corresponding
source files. Supply the approved policies before using those links in App Store
metadata.
