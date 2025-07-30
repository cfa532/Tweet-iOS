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
- `ChatBubbleShape.swift`: Custom shape for chat message bubbles
- `BadgeView.swift`: Notification badge component for unread messages

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
- 🔄 Integration with HproseInstance for backend communication
- 🔄 Real-time message updates
- 🔄 User avatar loading
- 🔄 Message persistence
- 🔄 Push notifications
- 🔄 Search API integration

## Usage

### Chat
1. Tap the "Chat" tab to view all conversations
2. Tap on a conversation to open the chat screen
3. Type messages in the input field and tap send

### Search
1. Tap the "Search" tab to open the search screen
2. Enter a username in the search field
3. Tap search or press enter to find users

## Architecture

The features follow the existing app architecture:
- MVVM pattern with ObservableObject
- SwiftUI for UI components
- Async/await for asynchronous operations
- Localization support for multiple languages

## Migration Notes

This implementation is based on the Android version located at:
`/Users/cfa532/AndroidStudioProjects/Tweet/app/src/main/java/us/fireshare/tweet`

Key differences from Android:
- Uses SwiftUI instead of Jetpack Compose
- iOS-specific navigation patterns
- Swift concurrency instead of Kotlin coroutines
- Core Data integration planned (vs Room in Android) 