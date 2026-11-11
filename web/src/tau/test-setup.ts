// What Web A's modules read from the browser when imported, which jsdom lacks
window.matchMedia ??= (query: string) => ({
  matches: false,
  media: query,
  addListener: () => undefined,
  removeListener: () => undefined,
  addEventListener: () => undefined,
  removeEventListener: () => undefined,
  dispatchEvent: () => false,
}) as unknown as MediaQueryList;
