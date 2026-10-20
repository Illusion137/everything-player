import type { StyleProp, ViewStyle } from 'react-native'

export type ResizeMode = 'contain' | 'cover' | 'stretch'

export interface VideoSurfaceProps {
  style?: StyleProp<ViewStyle>
  resizeMode?: ResizeMode
}
