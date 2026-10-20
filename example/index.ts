import '@origin/youtube/ytdl_polyfill'
import { registerRootComponent } from 'expo'
import nodejs from 'nodejs-mobile-react-native'
import App from './App'

nodejs.start('main.js')
registerRootComponent(App)
