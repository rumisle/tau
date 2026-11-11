// export { initApi, callApi, cancelApiProgress } from './methods/init';
export {
  initApi, closeApi, reconnectApi, callApi, cancelApiProgress, cancelApiProgressMaster, callApiLocal,
  handleMethodCallback,
  handleMethodResponse,
  updateFullLocalDb,
  updateLocalDb,
  setShouldEnableDebugLog,
} from '../../tau/api/connector'; // tau: the UI's API is tau's server (docs/web.md), not GramJS's worker
