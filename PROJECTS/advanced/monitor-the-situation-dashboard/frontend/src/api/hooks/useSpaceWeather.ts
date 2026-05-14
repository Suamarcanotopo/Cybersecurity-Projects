// ©AngelaMos | 2026
// useSpaceWeather.ts

import { useSnapshot } from '@/api/snapshot'
import { isValidSpaceWeatherData, type SpaceWeatherData } from '@/api/types'

export function useSpaceWeather(): SpaceWeatherData {
  const { data } = useSnapshot()
  const raw = data?.space_weather
  return isValidSpaceWeatherData(raw) ? raw : {}
}
