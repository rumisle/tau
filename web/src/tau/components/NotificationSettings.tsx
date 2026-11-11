// Settings > Notifications (iOS's NotificationsController, "In-App Notifications"): the page's notifications of
// answers (src/tau/notifications.ts) and their sound; in place of Web A's screen, whose kinds of chats, contacts and
// Web Push tau has none of.
import { memo, useCallback } from '../../lib/teact/teact';
import { getActions, withGlobal } from '../../global';

import { playNotifySound } from '../../util/notifications';
import { STRINGS } from '../strings';

import useHistoryBack from '../../hooks/useHistoryBack';
import useLang from '../../hooks/useLang';
import useRunDebounced from '../../hooks/useRunDebounced';

import Island, { IslandDescription, IslandTitle } from '../../components/gili/layout/Island';
import Checkbox from '../../components/ui/Checkbox';
import RangeSlider from '../../components/ui/RangeSlider';

type OwnProps = {
  isActive?: boolean;
  onReset: () => void;
};

type StateProps = {
  hasWebNotifications: boolean;
  notificationSoundVolume: number;
};

const NotificationSettings = ({
  isActive, onReset, hasWebNotifications, notificationSoundVolume,
}: OwnProps & StateProps) => {
  const { updateWebNotificationSettings } = getActions();
  const lang = useLang();
  const runDebounced = useRunDebounced(500, true);
  useHistoryBack({ isActive, onBack: onReset });

  const isSupported = 'Notification' in window;
  const isBlocked = isSupported && Notification.permission === 'denied';

  const handleChange = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    // Turned on, it asks for the browser's permission, and stays off without it
    updateWebNotificationSettings({ hasWebNotifications: e.target.checked });
  }, [updateWebNotificationSettings]);

  const handleVolumeChange = useCallback((volume: number) => {
    updateWebNotificationSettings({ notificationSoundVolume: volume });
    runDebounced(() => playNotifySound(undefined, volume));
  }, [runDebounced, updateWebNotificationSettings]);

  const isOn = hasWebNotifications && !isBlocked && isSupported;
  return (
    <div className="settings-content custom-scroll">
      <IslandTitle>{lang('NotificationsWeb')}</IslandTitle>
      <Island>
        <Checkbox
          label={STRINGS.NotificationsAnswers}
          subLabel={isBlocked ? STRINGS.NotificationsBlocked
            : lang(isOn ? 'UserInfoNotificationsEnabled' : 'UserInfoNotificationsDisabled')}
          checked={isOn}
          disabled={!isSupported || isBlocked}
          onChange={handleChange}
        />
        <RangeSlider
          label={lang('NotificationsSound')}
          min={0}
          max={10}
          disabled={!isOn}
          value={notificationSoundVolume}
          onChange={handleVolumeChange}
        />
      </Island>
      <IslandDescription>{STRINGS.NotificationsFooter}</IslandDescription>
    </div>
  );
};

export default memo(withGlobal<OwnProps>(
  (global): Complete<StateProps> => ({
    hasWebNotifications: global.settings.byKey.hasWebNotifications,
    notificationSoundVolume: global.settings.byKey.notificationSoundVolume,
  }),
)(NotificationSettings));
