# Chat and Search Features

This document describes the new chat and search features that have been added to the iOS Tweet app, migrated from the Android version.

## Features Added

### 1. Chat System

#### Data Models
- `ChatMessage.swift`: Represents individual chat messages with sender, receiver, content, and timestamp
- `ChatSession.swift`: Represents chat sessions/conversations with the last message and unread status

#### Screens
- `ChatListScreen.swift`: Shows a list of all chat conversations
- `ChatScreen.swift`: Individual chat conversation view with message input

#### Components
- `ChatRepository.swift`: Handles chat data operations and API calls
- `ChatMessageView.swift`: Chat message display with text and media attachments
- `ChatVideoPlayer`: Video player component for chat messages
- `ChatImageThumbnail`: Image display component for chat messages
- `ChatBubbleShape.swift`: Custom shape for chat message bubbles
- `BadgeView.swift`: Notification badge component for unread messages
- `ChatSessionManager.swift`: Manages chat sessions and unread counts

### 2. Search System

#### Screens
- `SearchScreen.swift`: User search interface with search bar and results

#### Components
- `SearchViewModel.swift`: Handles search logic and API calls

### 3. Navigation Updates

#### Tab Bar
The main navigation has been updated to include:
- Home (existing)
- Chat (new)
- Compose (existing)
- Search (new)

#### Localization
Added localization strings for:
- English (Localizable.strings)
- Japanese (ja.lproj/Localizable.strings)
- Chinese Simplified (zh-Hans.lproj/Localizable.strings)

### 4. Notifications

Added new notification types for chat events:
- `newChatMessageReceived`
- `chatMessageSent`
- `chatMessageSendFailed`

## Implementation Status

### Completed
- ✅ UI components and screens
- ✅ Navigation integration
- ✅ Localization strings
- ✅ Data models
- ✅ Basic repository structure

### TODO
- ✅ Integration with HproseInstance for backend communication
- ✅ Real-time message updates
- ✅ User avatar loading
- ✅ Message persistence
- ✅ Attachment support (images and videos)
- 🔄 Push notifications
- 🔄 Search API integration

## Media Attachments in Chat

### Video Attachments

**Display Layout (Matches Tweet Grid):**
- **Portrait videos** (aspect ratio < 0.9): Displayed in 0.9 aspect ratio grid (almost square)
- **Landscape videos**: Displayed using video's actual aspect ratio
- **Max width:** 70% of screen width
- **Overflow:** Clipped for clean appearance

**Playback Controls:**
- **Play/Pause Button** (bottom-left): 
  - Tap to play/pause video inline
  - Icon toggles between ▶️ and ⏸️
  - Size: 32px icon, 40px circle
  - Always visible (doesn't auto-hide)
  
- **Mute Button** (bottom-right):
  - Global mute state control
  - Synced across all videos in the app

- **Fullscreen**:
  - Tap anywhere on video (except buttons) to open fullscreen
  - Uses `MediaBrowserView` with full native controls
  - Dismisses back to chat with state preserved

**Video Caching:**
- ✅ Uses `CachingVideoPlayer` with `SharedAssetCache`
- ✅ Progressive download as video plays
- ✅ Disk persistence for offline playback
- ✅ Instant playback on second view
- ✅ Same cache shared with tweet videos

**Background Recovery:**
- ✅ Auto-pauses when app goes to background
- ✅ Saves playback position and state
- ✅ Auto-resumes when app returns to foreground
- ✅ Detects and recreates broken players
- ✅ Handles screen lock gracefully

**Upload Progress:**
- ✅ Shows upload dialog (same as tweets)
- ✅ Progress stages: Preparing → Uploading → Sending
- ✅ Real-time progress indicator
- ✅ Success/failure feedback
- ✅ Auto-dismisses on completion

### Image Attachments

**Display:**
- Max width: 70% of screen width
- Aspect ratio preserved
- Tap to open fullscreen in `MediaBrowserView`
- Progressive loading with thumbnail placeholder

**Upload Progress:**
- Same dialog system as videos
- Shows "Preparing attachment..." → "Uploading image" → "Sending message..."

## Usage

### Chat
1. Tap the "Chat" tab to view all conversations
2. Tap on a conversation to open the chat screen
3. Type messages in the input field and tap send

**Sending Attachments:**
1. Tap the paperclip icon
2. Select an image or video from library
3. Preview appears below input field
4. Tap send - upload dialog shows progress
5. Message appears in chat when complete

**Watching Videos:**
1. Tap play button (▶️) to watch inline
2. Tap pause button (⏸️) to pause
3. Tap video to open fullscreen viewer
4. Swipe down to dismiss fullscreen

### Search
1. Tap the "Search" tab to open the search screen
2. Enter a username in the search field
3. Tap search or press enter to find users

## Technical Implementation

### Chat Video Player

**Components:**
- `ChatVideoPlayer` - Main video display component in chat messages
- `ChatVideoPlayerContent` - Separate component handling playback state
- `CachingVideoPlayer` - Underlying player with caching support

**State Management:**
```swift
@State private var isPlaying: Bool = false  // Controls inline playback
@State private var showFullScreen: Bool = false  // Controls fullscreen modal
```

**Integration with Video System:**
- Uses `SharedAssetCache.getOrCreatePlayer()` for player management
- Shares player cache with tweet videos (same CID = same cache)
- Benefits from HLS playlist caching and progressive byte-range caching
- Participates in global memory management and cleanup

**Key Differences from Tweet Videos:**
- **Manual playback**: User controls play/pause (vs auto-play in grid)
- **Always visible controls**: Play button doesn't auto-hide
- **Inline + fullscreen**: Dual interaction mode (inline play OR fullscreen view)
- **Persistent state**: Play/pause state preserved across screen transitions
- **No HLS conversion**: Videos uploaded directly (no server-side processing)

### Upload System Integration

**Upload Manager:**
- Uses `UploadProgressManager.shared` for progress tracking
- Same system as tweet/comment uploads
- Type identifier: "chat" for analytics

**Upload Flow:**
```swift
1. User selects attachment → Preview shows
2. User taps send → UploadProgressManager.startUpload(type: "chat")
3. Preparing stage (10%) → Loading media data
4. Uploading stage (50%) → Upload to IPFS
5. Sending stage (90%) → Send message to server
6. Complete (100%) → Auto-dismiss after 1s
```

**Error Handling:**
- Upload failures shown in dialog (not toast)
- Failed messages added to chat with error indicator
- Retry available via message menu

## Architecture

The features follow the existing app architecture:
- MVVM pattern with ObservableObject
- SwiftUI for UI components
- Async/await for asynchronous operations
- Localization support for multiple languages
- Shared infrastructure with tweet/comment systems

## Migration Notes

This implementation is based on the Android version located at:
`/Users/cfa532/AndroidStudioProjects/Tweet/app/src/main/java/us/fireshare/tweet`

Key differences from Android:
- Uses SwiftUI instead of Jetpack Compose
- iOS-specific navigation patterns
- Swift concurrency instead of Kotlin coroutines
- Core Data integration planned (vs Room in Android) 