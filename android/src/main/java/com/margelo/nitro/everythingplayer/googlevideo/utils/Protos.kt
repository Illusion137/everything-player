package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.Cuepoint
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.CuepointInfo
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaCapabilities
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SabrContextUpdate
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.SsapPlaybackInfo
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamerContext

typealias CuepointTrackType = CuepointInfo.TrackType
typealias CuepointEvent = Cuepoint.CuepointEvent
typealias VideoFormatCapability = MediaCapabilities.VideoFormatCapability
typealias AudioFormatCapability = MediaCapabilities.AudioFormatCapability
typealias ClientInfo = StreamerContext.ClientInfo
typealias SabrContext = StreamerContext.SabrContext
typealias SabrContextScope = SabrContextUpdate.SabrContextScope
typealias SabrContextWritePolicy = SabrContextUpdate.SabrContextWritePolicy
typealias AdState = SsapPlaybackInfo.AdState
