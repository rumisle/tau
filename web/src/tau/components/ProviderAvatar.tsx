// A model provider's logo on its color, as an app icon (docs/accounts.md; iOS's ProviderIcon.swift); its initial on
// one of Telegram's avatar colors without a logo.
import buildClassName from '../../util/buildClassName';
import { providerLook } from '../api/providerIcons';

import styles from './AccountsSettings.module.scss';

const AVATAR_COLORS = ['#FF516A', '#FFA85C', '#B694F9', '#54CB68', '#2A9EF1', '#29D6E0', '#FF7EAB'];

/** The provider's logo on its color, as an app icon; its initial without a logo */
function ProviderAvatar({ provider, name, isLarge }: { provider: string; name: string; isLarge?: boolean }) {
  const look = providerLook(provider);
  const className = buildClassName(styles.avatar, isLarge && styles.large);
  if (!look) {
    let hash = 0;
    for (const char of provider) hash = (hash * 31 + char.charCodeAt(0)) % 65_536;
    return (
      <span className={className} style={`background-color: ${AVATAR_COLORS[hash % AVATAR_COLORS.length]}`}>
        {name.trim().charAt(0).toUpperCase()}
      </span>
    );
  }
  return (
    <span className={className} style={`background-color: ${look.background}`}>
      {look.foreground ? (
        <span
          className={styles.logo}
          style={`background-color: ${look.foreground}; mask-image: url(${look.logo}); `
            + `-webkit-mask-image: url(${look.logo})`}
        />
      ) : <img className={styles.logo} src={look.logo} alt="" />}
    </span>
  );
}

export default ProviderAvatar;
