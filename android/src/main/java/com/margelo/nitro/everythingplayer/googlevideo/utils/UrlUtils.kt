package com.margelo.nitro.everythingplayer.googlevideo.utils

import java.io.ByteArrayOutputStream

data class ByteRange(val start: Long, val end: Long)

private class UrlParts(val head: String, val query: String?, val fragment: String?) {
  fun build(query: String?): String = buildString {
    append(head)
    if (query != null) append('?').append(query)
    if (fragment != null) append('#').append(fragment)
  }

  companion object {
    fun parse(url: String): UrlParts {
      val hashIndex = url.indexOf('#')
      val beforeFragment = if (hashIndex >= 0) url.substring(0, hashIndex) else url
      val fragment = if (hashIndex >= 0) url.substring(hashIndex + 1) else null
      val queryIndex = beforeFragment.indexOf('?')
      return if (queryIndex >= 0) {
        UrlParts(beforeFragment.substring(0, queryIndex), beforeFragment.substring(queryIndex + 1), fragment)
      } else {
        UrlParts(beforeFragment, null, fragment)
      }
    }
  }
}

private const val URL_QUERY_VALUE_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$'()*,;:@/?"

private fun percentEncodeQueryValue(value: String): String = buildString {
  for (byte in value.toByteArray(Charsets.UTF_8)) {
    val c = (byte.toInt() and 0xff).toChar()
    if (byte >= 0 && URL_QUERY_VALUE_ALLOWED.indexOf(c) >= 0) {
      append(c)
    } else {
      append('%').append("%02X".format(byte.toInt() and 0xff))
    }
  }
}

private fun removingPercentEncoding(value: String): String? {
  val out = ByteArrayOutputStream()
  var i = 0
  while (i < value.length) {
    val c = value[i]
    if (c == '%') {
      if (i + 2 >= value.length) return null
      val hex = value.substring(i + 1, i + 3).toIntOrNull(16) ?: return null
      out.write(hex)
      i += 3
    } else {
      out.write(c.toString().toByteArray(Charsets.UTF_8))
      i += 1
    }
  }
  return out.toString(Charsets.UTF_8.name())
}

private fun queryItems(query: String?): MutableList<Pair<String, String?>> {
  if (query == null) return mutableListOf()
  return query.split('&').map { item ->
    val eq = item.indexOf('=')
    if (eq >= 0) item.substring(0, eq) to item.substring(eq + 1) else item to null
  }.toMutableList()
}

fun String.searchParam(name: String): String? {
  val items = queryItems(UrlParts.parse(this).query)
  return items.firstOrNull { it.first == name }?.second?.let { removingPercentEncoding(it) }
}

fun String.settingSearchParam(name: String, value: String): String {
  val parts = UrlParts.parse(this)
  val items = queryItems(parts.query)
  val encoded = percentEncodeQueryValue(value)
  val index = items.indexOfFirst { it.first == name }
  if (index >= 0) {
    items[index] = name to encoded
  } else {
    items.add(name to encoded)
  }
  return parts.build(items.joinToString("&") { if (it.second != null) "${it.first}=${it.second}" else it.first })
}

val String.urlHost: String?
  get() {
    val head = UrlParts.parse(this).head
    val schemeEnd = head.indexOf("://")
    if (schemeEnd < 0) return null
    val authority = head.substring(schemeEnd + 3).substringBefore('/')
    val hostPort = authority.substringAfterLast('@')
    val host = if (hostPort.startsWith("[")) hostPort.substringBefore(']') + "]" else hostPort.substringBefore(':')
    return host.ifEmpty { null }
  }

fun String.settingHost(host: String): String? {
  val current = urlHost ?: return null
  val schemeEnd = indexOf("://")
  val authorityStart = schemeEnd + 3
  val hostStart = indexOf(current, authorityStart)
  if (hostStart < 0) return null
  return substring(0, hostStart) + host + substring(hostStart + current.length)
}

fun parseRangeHeader(rangeHeaderValue: String?): ByteRange? {
  if (rangeHeaderValue.isNullOrEmpty()) return null

  val halves = rangeHeaderValue.split("=")
  if (halves.size <= 1) return null

  val parts = halves[1].split("-")
  if (parts.isNotEmpty()) {
    val start = parts[0].toLongOrNull() ?: 0
    val end = if (parts.size > 1) parts[1].toLongOrNull() ?: 0 else 0
    return ByteRange(start, end)
  }

  return null
}

fun getBroadcastId(url: String): String? {
  val idParam = url.searchParam("id")
  if (idParam.isNullOrEmpty()) return null
  val parts = idParam.split(".")
  return if (parts.size == 2) parts[1] else null
}

fun getNextFallbackUrl(input: String): String? {
  val fvip = input.searchParam("fvip")
  val mnRaw = input.searchParam("mn")
  val fallbackCount = input.searchParam("fallback_count")?.toIntOrNull() ?: 0

  if (!fvip.isNullOrEmpty() && !mnRaw.isNullOrEmpty()) {
    val mn = mnRaw.split(",")
    val nextIndex = fallbackCount + 1

    if (nextIndex < mn.size && mn[nextIndex].isNotEmpty()) {
      val nextNode = mn[nextIndex]
      val currentHost = input.urlHost ?: return null
      val suffix = currentHost.replace(Regex("^[^.]*"), "")
      val prefix = if (currentHost.startsWith("rr")) "rr" else "r"

      val url = input.settingHost("$prefix$fvip---$nextNode$suffix") ?: return null

      return url.settingSearchParam("fallback_count", (fallbackCount + 1).toString())
    }
  }

  return null
}
