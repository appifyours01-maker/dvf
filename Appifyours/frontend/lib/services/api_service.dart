import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart'; // For kIsWeb
import 'package:flutter/material.dart'; // For BuildContext
import 'dart:typed_data'; // For Uint8List
import 'dart:io' show File;
import 'package:http_parser/http_parser.dart'; // For MediaType
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:async'; // For StreamController

class GroqResponse {
  final bool success;
  final String? text;
  final String? error;
  final int? status;
  final int? retryAfter;

  GroqResponse({
    required this.success,
    this.text,
    this.error,
    this.status,
    this.retryAfter,
  });

  factory GroqResponse.fromJson(Map<String, dynamic> json) {
    return GroqResponse(
      success: json['success'] ?? false,
      text: json['text'],
      error: json['error'],
      status: json['status'],
      retryAfter: json['retryAfter'],
    );
  }
}

class ApiService {
  // Use environment variable for base URL
  late final String baseUrl;

  ApiService() {
    baseUrl = _resolveBaseUrl();
  }

  String _resolveBaseUrl() {
    final configured = (dotenv.env['API_BASE'] ?? '').trim();
    const fallback = 'http://127.0.0.1:5000';
    final raw = configured.isEmpty ? fallback : configured;

    if (kIsWeb && raw.contains('localhost')) {
      return raw.replaceFirst('localhost', '127.0.0.1');
    }

    if (kIsWeb) {
      final host = Uri.base.host;
      if (host == 'localhost' || host == '127.0.0.1') {
        final uri = Uri.tryParse(raw);
        final configuredHost = uri?.host ?? '';
        if (configuredHost.isNotEmpty && configuredHost != host) {
          return fallback;
        }
      }
    }

    return raw;
  }
  
  // Real-time WebSocket connection
  IO.Socket? _socket;
  final StreamController<Map<String, dynamic>> _realTimeUpdateController = 
      StreamController<Map<String, dynamic>>.broadcast();
  
  // Stream for real-time updates
  Stream<Map<String, dynamic>> get realTimeUpdates => _realTimeUpdateController.stream;
  
  // Connection status
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  // Get the stored token
  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  Future<String?> _getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('user_id');
    print('Retrieved User ID from storage: $userId');
    return userId;
  }

  Future<List<Map<String, dynamic>>> getAppDetails() async {
    try {
      final response = await get('/api/user/app-details');
      if (response.statusCode == 200) {
        final dynamic decoded = json.decode(response.body);
        
        // If the response is wrapped in an object
        if (decoded is Map<String, dynamic>) {
          // Adjust 'data' to match your actual API response key
          final List<dynamic> data = decoded['data'] ?? decoded['apps'] ?? [];
          return data.map<Map<String, dynamic>>((item) {
            return Map<String, dynamic>.from(item);
          }).toList();
        } 
        // If the response is already a list
        else if (decoded is List) {
          return decoded.map<Map<String, dynamic>>((item) {
            return Map<String, dynamic>.from(item);
          }).toList();
        } else {
          throw Exception('Unexpected response format');
        }
      } else {
        throw Exception('Failed to load app details: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to load app details: $e');
    }
  }

  // ===== ORDERS METHODS =====

  Future<List<Map<String, dynamic>>> getOrders() async {
    try {
      final response = await get('/api/user/orders');
      if (response.statusCode == 200) {
        final dynamic decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) {
          final List<dynamic> data = decoded['data'] ?? decoded['orders'] ?? [];
          return data.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
        if (decoded is List) {
          return decoded.map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
        return [];
      } else {
        throw Exception('Failed to fetch orders: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to fetch orders: $e');
    }
  }

  Future<Map<String, dynamic>> saveOrder(Map<String, dynamic> orderData) async {
    try {
      final response = await post('/api/user/orders', orderData);
      if (response.statusCode == 200 || response.statusCode == 201) {
        return json.decode(response.body) as Map<String, dynamic>;
      } else {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Failed to save order');
      }
    } catch (e) {
      throw Exception('Failed to save order: $e');
    }
  }

  // ===== END ORDERS METHODS =====

  // Upload profile photo - works on both web and mobile
  Future<Map<String, dynamic>> uploadProfilePhoto(dynamic imageFile) async {
    try {
      final token = await _getToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      print('=== UPLOADING PROFILE PHOTO ===');
      print('Using base URL: $baseUrl');

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/api/user/profile/photo'),
      );

      request.headers['Authorization'] = 'Bearer $token';

      http.MultipartFile multipartFile;

      if (kIsWeb) {
        // For web: imageFile should be Uint8List
        print('Platform: Web');
        if (imageFile is! Uint8List) {
          throw Exception('Invalid image data for web platform');
        }
        
        multipartFile = http.MultipartFile.fromBytes(
          'photo',
          imageFile,
          filename: 'profile_photo.jpg',
          contentType: MediaType('image', 'jpeg'),
        );
      } else {
        // For mobile/desktop: imageFile should be File
        print('Platform: Mobile/Desktop');
        print('File path: ${imageFile.path}');
        
        if (imageFile is! File) {
          throw Exception('Invalid image file for mobile platform');
        }
        
        multipartFile = await http.MultipartFile.fromPath(
          'photo',
          imageFile.path,
        );
      }

      request.files.add(multipartFile);

      print('Sending request...');
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('Photo uploaded successfully');
        return data;
      } else {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Failed to upload photo');
      }
    } catch (e) {
      print('Error uploading photo: $e');
      throw Exception('Failed to upload photo: $e');
    }
  }

  // Delete profile photo
  Future<void> deleteProfilePhoto() async {
    try {
      final response = await delete('/api/user/profile/photo');
      
      if (response.statusCode != 200) {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Failed to delete photo');
      }
    } catch (e) {
      throw Exception('Failed to delete photo: $e');
    }
  }

  // Generic GET request with token
  Future<http.Response> get(String endpoint) async {
    final token = await _getToken();

    if (token == null) {
      throw Exception('No authentication token found');
    }

    final response = await http.get(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 401) {
      throw Exception('Token expired or invalid');
    }

    return response;
  }

  // Generic POST request with token
  Future<http.Response> post(String endpoint, Map<String, dynamic> body) async {
    final token = await _getToken();

    if (token == null) {
      throw Exception('No authentication token found');
    }

    final response = await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 401) {
      throw Exception('Token expired or invalid');
    }

    return response;
  }

  // Generic PUT request with token
  Future<http.Response> put(String endpoint, Map<String, dynamic> body) async {
    final token = await _getToken();

    if (token == null) {
      throw Exception('No authentication token found');
    }

    final response = await http.put(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode == 401) {
      throw Exception('Token expired or invalid');
    }

    return response;
  }

  // Generic DELETE request with token and optional body
  Future<http.Response> delete(String endpoint, [Map<String, dynamic>? body]) async {
    final token = await _getToken();

    if (token == null) {
      throw Exception('No authentication token found');
    }

    http.Response response;
    
    if (body != null) {
      response = await http.delete(
        Uri.parse('$baseUrl$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body),
      );
    } else {
      response = await http.delete(
        Uri.parse('$baseUrl$endpoint'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
    }

    if (response.statusCode == 401) {
      throw Exception('Token expired or invalid');
    }

    return response;
  }

  // POST without token (for login, register, etc.)
  Future<http.Response> postWithoutAuth(String endpoint, Map<String, dynamic> body) async {
    return await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
  }

  // Get JSON response directly
  Future<Map<String, dynamic>> getJson(String endpoint) async {
    final response = await get(endpoint);
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('Failed to load data: ${response.statusCode}');
    }
  }

  // Get user profile
  Future<Map<String, dynamic>> getUserProfile() async {
    try {
      final response = await get('/api/user/profile');
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        
        // Check if the response contains the user data
        if (data['success'] == true && data['user'] != null) {
          return data['user'];
        }
        return data;
      } else {
        throw Exception('Failed to fetch user profile: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to fetch user profile: $e');
    }
  }

  // Add this method to your ApiService.dart
  Future<String?> refreshProfilePhotoUrl(String s3Key) async {
    try {
      final token = await _getToken();
      if (token == null) {
        throw Exception('No authentication token found');
      }

      final response = await http.get(
        Uri.parse('$baseUrl/api/user/profile/photo/presigned-url?key=$s3Key'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true && data['presignedUrl'] != null) {
          return data['presignedUrl'];
        }
      }
      return null;
    } catch (e) {
      print('Error refreshing profile photo URL: $e');
      return null;
    }
  }

  // Business details
  Future<Map<String, dynamic>?> getBusinessDetails() async {
    try {
      final data = await getJson('/api/user/business/details');
      print('Business details response: $data');
      // Extract the business object from the response
      if (data['success'] == true && data['business'] != null) {
        return data['business'];
      }
      return data;
    } catch (e) {
      print('Failed to fetch business details: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> profileData) async {
    try {
      final response = await put('/api/user/profile', profileData);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data;
      } else {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Failed to update profile');
      }
    } catch (e) {
      throw Exception('Failed to update profile: $e');
    }
  }

  Future<Map<String, dynamic>> updateBusinessDetails(Map<String, dynamic> businessData) async {
    try {
      print('=== API SERVICE: updateBusinessDetails ===');
      print('Business data to update: $businessData');

      final response = await put('/api/user/business/details', businessData);

      print('Response status code: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('Decoded response: $data');
        return data;
      } else {
        final error = json.decode(response.body);
        print('Error response: $error');
        throw Exception(error['message'] ?? 'Failed to update business details');
      }
    } catch (e, stackTrace) {
      print('=== ERROR IN updateBusinessDetails ===');
      print('Error: $e');
      print('Stack trace: $stackTrace');
      throw Exception('Failed to update business details: $e');
    }
  }

  // Change password
  Future<void> changePassword(String currentPassword, String newPassword) async {
    try {
      final response = await put('/api/user/change-password', {
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      });

      if (response.statusCode != 200) {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Failed to change password');
      }
    } catch (e) {
      throw Exception('Failed to change password: $e');
    }
  }

  // Login method
  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      final response = await postWithoutAuth('/api/signin', {
        'username': email,
        'password': password,
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', data['token']);
        await prefs.setString('user_id', data['user']['_id'] ?? data['user']['id']);

        return data;
      } else {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Login failed');
      }
    } catch (e) {
      throw Exception('Login failed: $e');
    }
  }

  // Register method
  Future<Map<String, dynamic>> register({
    required String firstName,
    required String lastName,
    required String phone,
    required String email,
    required String password,
  }) async {
    try {
      final response = await postWithoutAuth('/api/create-account', {
        'firstName': firstName,
        'lastName': lastName,
        'phone': phone,
        'email': email,
        'password': password,
      });

      if (response.statusCode == 201) {
        final data = json.decode(response.body);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', data['token']);
        await prefs.setString('user_id', data['user']['_id'] ?? data['user']['id']);

        return data;
      } else {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Registration failed');
      }
    } catch (e) {
      throw Exception('Registration failed: $e');
    }
  }

  // Logout method
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_id');
  }

  // Handle 401 Unauthorized errors
  Future<void> handleUnauthorizedError(BuildContext context) async {
    await logout();
    if (context.mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    }
  }

  // Check if user is logged in
  Future<bool> isLoggedIn() async {
    final token = await _getToken();
    return token != null;
  }

  // Create a new shop
  Future<Map<String, dynamic>> createShop(Map<String, dynamic> shopData) async {
    try {
      print('Creating shop with data: $shopData');
      print('Using base URL: $baseUrl');
      final response = await post('/api/shops', shopData);

      print('Response status code: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 201) {
        return json.decode(response.body);
      } else {
        final error = json.decode(response.body);
        throw Exception(error['message'] ?? 'Failed to create shop');
      }
    } catch (e) {
      print('Error creating shop: $e');
      throw Exception('Failed to create shop: $e');
    }
  }

  Future<http.Response> getWithoutAuth(String endpoint) async {
    return await http.get(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
      },
    );
  }

  Future<List<Map<String, dynamic>>> getUserSubscriptions() async {
    try {
      final userId = await _getUserId();
      print('Fetching subscriptions for User ID: $userId');
      print('Using base URL: $baseUrl');

      final response = await get('/api/user-subscriptions');

      print('Response status code: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        print('Decoded response data: $data');

        if (data.containsKey('subscriptions') && data['subscriptions'] is List) {
          final List<dynamic> subscriptions = data['subscriptions'];
          print('Found subscriptions list: $subscriptions');

          return subscriptions.map<Map<String, dynamic>>((item) {
            return Map<String, dynamic>.from(item);
          }).toList();
        } else {
          print('Error: Response does not contain subscriptions list');
          throw Exception('Response does not contain subscriptions list');
        }
      } else {
        final error = json.decode(response.body);
        print('Error response: $error');
        throw Exception(error['message'] ?? 'Failed to load subscriptions');
      }
    } catch (e) {
      print('Exception in getUserSubscriptions: $e');
      throw Exception('Failed to load subscriptions: $e');
    }
  }

  // Check if user has already created a shop
  Future<bool> hasExistingShop() async {
    try {
      final userId = await _getUserId();
      print('ApiService: Checking if user has existing shop for User ID: $userId');
      
      final response = await get('/api/shops');
      
      print('ApiService: Shop check response status: ${response.statusCode}');
      print('ApiService: Shop check response body: ${response.body}');
      
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        
        // Check if hasShops field is present (new backend format)
        if (data.containsKey('hasShops')) {
          final bool hasShops = data['hasShops'] ?? false;
          print('ApiService: Backend hasShops field: $hasShops');
          return hasShops;
        }
        
        // Check data array length (current backend format)
        if (data.containsKey('data') && data['data'] is List) {
          final List<dynamic> shops = data['data'];
          print('ApiService: Found ${shops.length} shops for user');
          return shops.isNotEmpty;
        }
        
        print('ApiService: No valid shop data found in response');
        return false;
      } else if (response.statusCode == 404) {
        // No shops found for user
        print('ApiService: No shops found for user (404)');
        return false;
      } else {
        print('ApiService: Error checking existing shop: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('ApiService: Exception in hasExistingShop: $e');
      // If there's an error, assume no shop exists to be safe
      return false;
    }
  }

  // Check if user has incomplete app drafts
  Future<bool> hasIncompleteDrafts() async {
    try {
      final userId = await _getUserId();
      print('ApiService: Checking if user has incomplete drafts for User ID: $userId');

      if (userId == null) {
        print('ApiService: No user ID found');
        return false;
      }

      final response = await get('/api/draftscreen?userId=$userId');

      print('ApiService: Drafts check response status: ${response.statusCode}');
      print('ApiService: Drafts check response body: ${response.body}');

      if (response.statusCode == 200) {
        final List<dynamic> drafts = jsonDecode(response.body);
        print('ApiService: Found ${drafts.length} total drafts for user');

        // Check if there are any drafts with status 'draft' and progress < 100
        final incompleteDrafts = drafts.where((draft) =>
          draft['status'] == 'draft' && (draft['progress'] ?? 0) < 100
        ).toList();

        print('ApiService: Found ${incompleteDrafts.length} incomplete drafts');
        return incompleteDrafts.isNotEmpty;
      } else if (response.statusCode == 404) {
        print('ApiService: No drafts found for user (404)');
        return false;
      } else {
        print('ApiService: Error checking drafts: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('ApiService: Exception in hasIncompleteDrafts: $e');
      // If there's an error, assume no incomplete drafts exist to be safe
      return false;
    }
  }

  // Check if user has any completed apps
  Future<bool> hasCompletedApps() async {
    try {
      final userId = await _getUserId();
      print('ApiService: Checking if user has completed apps for User ID: $userId');

      if (userId == null) {
        print('ApiService: No user ID found');
        return false;
      }

      final response = await get('/api/draftscreen/has-completed-apps/$userId');

      print('ApiService: Completed apps check response status: ${response.statusCode}');
      print('ApiService: Completed apps check response body: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> decoded = jsonDecode(response.body);
        if (decoded['success'] == true) {
          final bool hasCompletedAppsResult = decoded['hasCompletedApps'] ?? false;
          print('ApiService: User has completed apps: $hasCompletedAppsResult');
          return hasCompletedAppsResult;
        } else {
          print('ApiService: Response success is false');
          return false;
        }
      } else if (response.statusCode == 404) {
        print('ApiService: No completed apps found for user (404)');
        return false;
      } else {
        print('ApiService: Error checking completed apps: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('ApiService: Exception in hasCompletedApps: $e');
      // If there's an error, assume no completed apps exist to be safe
      return false;
    }
  }

  // Check if user has any apps (incomplete drafts or completed apps)
  Future<bool> hasAnyApps() async {
    try {
      final userId = await _getUserId();
      print('ApiService: Checking if user has any apps for User ID: $userId');

      if (userId == null) {
        print('ApiService: No user ID found');
        return false;
      }

      // Check incomplete drafts first
      final hasIncompleteDraftsResult = await hasIncompleteDrafts();
      print('ApiService: hasIncompleteDrafts result: $hasIncompleteDraftsResult');

      if (hasIncompleteDraftsResult) {
        print('ApiService: User has incomplete drafts');
        return true;
      }

      // Check completed apps
      final hasCompletedAppsResult = await hasCompletedApps();
      print('ApiService: hasCompletedApps result: $hasCompletedAppsResult');

      if (hasCompletedAppsResult) {
        print('ApiService: User has completed apps');
        return true;
      }

      print('ApiService: User has no apps');
      return false;
    } catch (e) {
      print('ApiService: Exception in hasAnyApps: $e');
      return false;
    }
  }
  
  Future<Map<String, dynamic>?> getDraftInfo() async {
    try {
      final userId = await _getUserId();
      print('ApiService: Fetching draft info for User ID: $userId');

      if (userId == null) {
        print('ApiService: No user ID found');
        return null;
      }

      final response = await get('/api/draft-info/$userId');

      print('ApiService: Draft info response status: ${response.statusCode}');
      print('ApiService: Draft info response body: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> decoded = jsonDecode(response.body);
        if (decoded['success'] == true && decoded['data'] != null) {
          print('ApiService: Successfully fetched draft info');
          return decoded['data'];
        } else {
          print('ApiService: Response success is false or no data');
          return null;
        }
      }
      return null;
    } catch (e) {
      print('ApiService: Exception in getDraftInfo: $e');
      return null;
    }
  }

  // Check if user has an active subscription
  Future<bool> hasActiveSubscription() async {
    try {
      final userId = await _getUserId();
      print('ApiService: Checking active subscription for User ID: $userId');

      if (userId == null) {
        print('ApiService: No user ID found');
        return false;
      }

      // Try to current-subscription endpoint first (more efficient)
      final currentSubResponse = await get('/api/current-subscription');
      print('ApiService: Current subscription check response status: ${currentSubResponse.statusCode}');
      print('ApiService: Current subscription check response body: ${currentSubResponse.body}');

      if (currentSubResponse.statusCode == 200) {
        final responseData = json.decode(currentSubResponse.body);
        if (responseData['subscription'] != null) {
          final subscription = responseData['subscription'];
          final status = subscription['status']?.toString().toLowerCase();
          print('ApiService: Found current subscription with status: $status');
          
          if (status == 'active') {
            print('ApiService: User has active current subscription');
            return true;
          }
        }
      } else if (currentSubResponse.statusCode == 404) {
        print('ApiService: No current subscription found (404)');
        return false;
      }

      // Fallback to user-subscriptions endpoint
      final response = await get('/api/user-subscriptions');
      print('ApiService: Fallback subscription check response status: ${response.statusCode}');
      print('ApiService: Fallback subscription check response body: ${response.body}');

      if (response.statusCode == 200) {
        final responseBody = response.body.trim();
        if (responseBody.isEmpty || responseBody == '[]') {
          print('ApiService: Empty subscription response');
          return false;
        }

        // Handle both response formats
        dynamic responseData = json.decode(responseBody);
        List<dynamic> subscriptions;
        
        if (responseData is Map && responseData['subscriptions'] != null) {
          // Format from save-subscription.js
          subscriptions = responseData['subscriptions'];
        } else if (responseData is List) {
          // Format from user_subscriptions.js
          subscriptions = responseData;
        } else {
          print('ApiService: Unexpected response format');
          return false;
        }

        print('ApiService: Found ${subscriptions.length} subscriptions');
        
        // Check if user has any active subscription
        final now = DateTime.now();
        for (var subscription in subscriptions) {
          print('ApiService: Checking subscription: $subscription');
          
          final status = subscription['status']?.toString().toLowerCase();
          
          print('ApiService: Subscription status: $status');
          
          // If status is active, user has valid subscription
          if (status == 'active' || status == 'approved') {
            // Check end date if available
            final endDateStr = subscription['endDate'] ?? subscription['end_date'];
            if (endDateStr != null) {
              try {
                final endDate = DateTime.parse(endDateStr);
                if (endDate.isAfter(now)) {
                  print('ApiService: Found active subscription valid until: $endDate');
                  return true;
                }
              } catch (e) {
                print('ApiService: Error parsing end date, assuming active: $e');
                return true;
              }
            } else {
              print('ApiService: Found active subscription with no end date');
              return true;
            }
          }
        }
        
        print('ApiService: No active subscription found');
        return false;
      } else {
        print('ApiService: Error checking subscription: ${response.statusCode} - ${response.body}');
        return false;
      }
    } catch (e) {
      print('ApiService: Exception in hasActiveSubscription: $e');
      return false;
    }
  }

  // Get available subscription plans
  Future<List<Map<String, dynamic>>> getSubscriptionPlans() async {
    try {
      print('ApiService: Fetching subscription plans');
      
      final response = await getWithoutAuth('/api/subscription-plans');
      
      print('ApiService: Subscription plans response status: ${response.statusCode}');
      print('ApiService: Subscription plans response body: ${response.body}');
      
      if (response.statusCode == 200) {
        final List<dynamic> plans = jsonDecode(response.body);
        print('ApiService: Raw plans data: $plans');
        final formattedPlans = plans.map<Map<String, dynamic>>((plan) => Map<String, dynamic>.from(plan)).toList();
        print('ApiService: Formatted plans: $formattedPlans');
        return formattedPlans;
      } else {
        throw Exception('Failed to load subscription plans: ${response.statusCode}');
      }
    } catch (e) {
      print('ApiService: Exception in getSubscriptionPlans: $e');
      throw Exception('Failed to load subscription plans: $e');
    }
  }
  
  // Get users by admin ID (uses logged-in user's ID as adminId)
  Future<List<Map<String, dynamic>>> getUsersByAdmin() async {
    try {
      final userId = await _getUserId();
      print('Fetching users for Admin ID (User ID): $userId');
      print('Using base URL: $baseUrl');

      if (userId == null) {
        print('Error: No user ID found in storage');
        throw Exception('No user ID found. Please log in again.');
      }

      final response = await get('/api/users/by-admin/$userId');

      print('Response status code: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);
        print('Decoded response data: $data');

        if (data['success'] == true && data['data'] is List) {
          final List<dynamic> users = data['data'];
          print('Found users list: $users');

          return users.map<Map<String, dynamic>>((item) {
            return Map<String, dynamic>.from(item);
          }).toList();
        } else {
          print('Error: Response success is false or data is not a list');
          // Return empty list instead of throwing error
          return [];
        }
      } else if (response.statusCode == 404) {
        print('No users found for this admin (404)');
        return [];
      } else {
        final error = json.decode(response.body);
        print('Error response: $error');
        throw Exception(error['message'] ?? 'Failed to load users');
      }
    } catch (e) {
      print('Exception in getUsersByAdmin: $e');
      throw Exception('Failed to load users: $e');
    }
  }


// Submit support request
  Future<Map<String, dynamic>> submitSupport({
    required String name,
    required String email,
    required String message,
    String? userId,
  }) async {
    try {
      print('Submitting support request from: $name ($email)');
      
      final response = await postWithoutAuth('/api/support', {
        'name': name,
        'email': email,
        'message': message,
        'userId': userId,
      });

      print('Support request response status: ${response.statusCode}');
      print('Support request response body: ${response.body}');

      if (response.statusCode == 201) {
        final data = json.decode(response.body);
        print('Support request submitted successfully');
        return {
          'success': true,
          'message': 'Support request submitted successfully',
          'data': data,
        };
      } else {
        final error = json.decode(response.body);
        print('Support request submission failed: ${error['message'] ?? 'Unknown error'}');
        return {
          'success': false,
          'message': error['message'] ?? 'Failed to submit support request',
          'error': error,
        };
      }
    } catch (e) {
      print('Exception in submitSupport: $e');
      return {
        'success': false,
        'message': 'Failed to submit support request: $e',
      };
    }
  }

  
  // ===== NEW METHODS FOR DYNAMIC FEATURES =====

  // Get app name for splash screen
  Future<Map<String, dynamic>> getAppName({String? adminId}) async {
    try {
      print('Getting app name with adminId: $adminId');
      
      // Build URL with adminId parameter
      String url = '$baseUrl/api/admin/splash';
      if (adminId != null && adminId.isNotEmpty) {
        url += '?adminId=$adminId';
      }
      
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('Failed to get app name: ${response.statusCode}');
      }
    } catch (e) {
      print('Error getting app name: $e');
      // Return fallback data
      return {
        'adminId': adminId ?? '',
        'appName': 'MyApp',
        'shopName': 'Default Shop'
      };
    }
  }

  // Get form data for dynamic widget generation
  Future<Map<String, dynamic>> getFormData({String? adminId}) async {
    try {
      print('Getting form data with adminId: $adminId');
      
      // Build URL with adminId parameter
      String url = '$baseUrl/api/get-form';
      if (adminId != null && adminId.isNotEmpty) {
        url += '?adminId=$adminId';
      }
      
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('Form data fetched successfully: ${data.keys}');
        return data;
      } else {
        throw Exception('Failed to get form data: ${response.statusCode}');
      }
    } catch (e) {
      print('Error getting form data: $e');
      // Return fallback data
      return {
        'success': false,
        'pages': [],
        'widgets': [],
        'error': e.toString()
      };
    }
  }

  // Get app info for admin-user linking
  Future<Map<String, dynamic>> getAppInfo() async {
    try {
      print('Getting app info - using baseUrl: $baseUrl');
      
      final response = await http.get(
        Uri.parse('$baseUrl/api/admin/app-info'),
        headers: {
          'Content-Type': 'application/json',
        },
      );

      print('App info response status: ${response.statusCode}');
      print('App info response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        print('App info request failed with status: ${response.statusCode}');
        return {
          'success': false,
          'data': {
            'adminId': '', // No hardcoded fallback
            'appName': 'MyApp',
            'company': 'Appifyours',
            'version': '1.0.0'
          }, // Fallback
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('Error getting app info: $e');
      return {
        'success': false,
        'data': {
          'adminId': '', // No hardcoded fallback
          'appName': 'MyApp',
          'company': 'Appifyours',
          'version': '1.0.0'
        }, // Fallback
        'statusCode': 500,
      };
    }
  }

  // Enhanced signup with admin and shop linking
  Future<Map<String, dynamic>> dynamicSignupWithAdmin({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
    String? adminId,
    String? shopName,
  }) async {
    try {
      print('Dynamic signup with admin and shop - using baseUrl: $baseUrl');
      
      // First get app info to determine admin ID and shop name if not provided
      String linkedAdminId = adminId ?? '';
      String linkedShopName = shopName ?? '';
      
      if (linkedAdminId.isEmpty || linkedShopName.isEmpty) {
        final appInfoResult = await getAppInfo();
        if (appInfoResult['success'] == true && appInfoResult['data'] != null) {
          linkedAdminId = linkedAdminId.isEmpty ? (appInfoResult['data']['adminId'] ?? '') : linkedAdminId;
          linkedShopName = linkedShopName.isEmpty ? (appInfoResult['data']['shopName'] ?? 'Default Shop') : linkedShopName;
        } else {
          linkedAdminId = linkedAdminId.isEmpty ? '' : linkedAdminId; // No hardcoded fallback
          linkedShopName = linkedShopName.isEmpty ? 'Default Shop' : linkedShopName;
        }
      }

      final response = await http.post(
        Uri.parse('$baseUrl/api/signup'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'firstName': firstName,
          'lastName': lastName,
          'email': email,
          'password': password,
          'phone': phone ?? '',
          'adminId': linkedAdminId,
          'shopName': linkedShopName,
        }),
      );

      print('Signup with admin and shop response status: ${response.statusCode}');
      print('Signup with admin and shop response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        print('Signup with admin and shop request failed with status: ${response.statusCode}');
        return {
          'success': false,
          'data': null,
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('Error in signup with admin and shop: $e');
      return {
        'success': false,
        'data': null,
        'statusCode': 500,
      };
    }
  }

  // ===== END ADMIN-USER LINKING METHODS =====

  // Get home page widgets for dynamic app
  Future<Map<String, dynamic>> getHomeWidgets({String? adminId}) async {
    try {
      print('Getting home widgets with adminId: $adminId');
      
      // Build URL with adminId parameter
      String url = '$baseUrl/api/admin/home';
      if (adminId != null && adminId.isNotEmpty) {
        url += '?adminId=$adminId';
      }
      
      final response = await http.get(Uri.parse(url));
      print('Home widgets response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        print('Home widgets request failed with status: ${response.statusCode}');
        return {
          'success': false,
          'data': null,
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('Error getting home widgets: $e');
      return {
        'success': false,
        'data': null,
        'statusCode': 500,
      };
    }
  }

  // ===== WISHLIST METHODS =====

  // Get wishlist count and items
  Future<Map<String, dynamic>> getWishlist({String? userId}) async {
    try {
      print('Getting wishlist - using baseUrl: $baseUrl');
      final response = await http.get(
        Uri.parse('$baseUrl/api/admin/wishlist?userId=${userId ?? 'demo_user'}'),
        headers: {
          'Content-Type': 'application/json',
        },
      );

      print('Wishlist response status: ${response.statusCode}');
      print('Wishlist response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        print('Wishlist request failed with status: ${response.statusCode}');
        return {
          'success': false,
          'data': {'wishlistCount': 0, 'wishlistItems': []}, // Fallback
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('Error getting wishlist: $e');
      return {
        'success': false,
        'data': {'wishlistCount': 0, 'wishlistItems': []}, // Fallback
        'statusCode': 500,
      };
    }
  }

  // Add item to wishlist
  Future<Map<String, dynamic>> addToWishlist({
    required String userId,
    required String productId,
    String? productName,
    double? productPrice,
  }) async {
    try {
      print('Adding to wishlist - using baseUrl: $baseUrl');
      final response = await http.post(
        Uri.parse('$baseUrl/api/admin/wishlist/add'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'userId': userId,
          'productId': productId,
          'productName': productName ?? 'Product $productId',
          'productPrice': productPrice ?? 0.0,
        }),
      );

      print('Add to wishlist response status: ${response.statusCode}');
      print('Add to wishlist response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        print('Add to wishlist request failed with status: ${response.statusCode}');
        return {
          'success': false,
          'data': {'wishlistCount': 0},
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('Error adding to wishlist: $e');
      return {
        'success': false,
        'data': {'wishlistCount': 0},
        'statusCode': 500,
      };
    }
  }

  // Remove item from wishlist
  Future<Map<String, dynamic>> removeFromWishlist({
    required String userId,
    required String productId,
  }) async {
    try {
      print('Removing from wishlist - using baseUrl: $baseUrl');
      final response = await http.post(
        Uri.parse('$baseUrl/api/admin/wishlist/remove'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'userId': userId,
          'productId': productId,
        }),
      );

      print('Remove from wishlist response status: ${response.statusCode}');
      print('Remove from wishlist response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        print('Remove from wishlist request failed with status: ${response.statusCode}');
        return {
          'success': false,
          'data': {'wishlistCount': 0},
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('Error removing from wishlist: $e');
      return {
        'success': false,
        'data': {'wishlistCount': 0},
        'statusCode': 500,
      };
    }
  }

  // ===== END WISHLIST METHODS =====

  // Dynamic signup method for new system
  Future<Map<String, dynamic>> dynamicSignup({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? phone,
    String? adminId,
    String? appId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/signup'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'firstName': firstName,
          'lastName': lastName,
          'email': email,
          'password': password,
          'phone': phone ?? '',
          if (adminId != null && adminId.isNotEmpty) 'adminId': adminId,
          if (appId != null && appId.isNotEmpty) 'appId': appId,
        }),
      );

      print('Dynamic Signup Response Status: ${response.statusCode}');
      print('Dynamic Signup Response Body: ${response.body}');

      final decoded = json.decode(response.body);
      final isOkStatus = response.statusCode == 200 || response.statusCode == 201;
      final isSuccessFlag = decoded is Map<String, dynamic> && decoded['success'] == true;

      String? token;
      String? userId;
      if (decoded is Map<String, dynamic>) {
        token = decoded['token']?.toString();
        final user = decoded['user'];
        if (user is Map<String, dynamic>) {
          userId = user['_id']?.toString();
        }
      }

      return {
        'success': isOkStatus && (decoded is Map<String, dynamic> ? (decoded['success'] == true) : true),
        'data': decoded,
        'statusCode': response.statusCode,
        'token': token,
        'userId': userId,
      };
    } catch (e) {
      print('Dynamic Signup Error: $e');
      return {
        'success': false,
        'data': {'message': 'Network error: $e'},
        'statusCode': 500,
        'token': null,
        'userId': null,
      };
    }
  }

  // Dynamic login method for new system
  Future<Map<String, dynamic>> dynamicLogin({
    required String email,
    required String password,
    String? adminId,
    String? appId,
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/login'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'email': email,
          'password': password,
          if (adminId != null && adminId.isNotEmpty) 'adminId': adminId,
          if (appId != null && appId.isNotEmpty) 'appId': appId,
        }),
      );

      print('Dynamic Login Response Status: ${response.statusCode}');
      print('Dynamic Login Response Body: ${response.body}');

      final decoded = json.decode(response.body);
      String? token;
      String? userId;
      if (decoded is Map<String, dynamic>) {
        token = decoded['token']?.toString();
        final user = decoded['user'];
        if (user is Map<String, dynamic>) {
          userId = user['_id']?.toString();
        }
      }

      return {
        'success': response.statusCode == 200,
        'data': decoded,
        'statusCode': response.statusCode,
        'token': token,
        'userId': userId,
      };
    } catch (e) {
      print('Dynamic Login Error: $e');
      return {
        'success': false,
        'data': {'message': 'Network error: $e'},
        'statusCode': 500,
        'token': null,
        'userId': null,
      };
    }
  }

  // Get dynamic app configuration
  Future<Map<String, dynamic>> getDynamicAppConfig() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/app/config'),
        headers: {
          'Content-Type': 'application/json',
        },
      );

      print('Dynamic App Config Response Status: ${response.statusCode}');
      print('Dynamic App Config Response Body: ${response.body}');

      return {
        'success': response.statusCode == 200,
        'data': json.decode(response.body),
        'statusCode': response.statusCode,
      };
    } catch (e) {
      print('Dynamic App Config Error: $e');
      return {
        'success': false,
        'data': {
          'config': {
            'appName': 'MyApp',
            'themeColor': '#2196F3',
            'bannerImage': '',
          }
        },
        'statusCode': 500,
      };
    }
  }

  // Send message to Groq
  Future<GroqResponse> sendMessageToGroq(String prompt) async {
    try {
      final token = await _getToken();
      
      // Make sure to include /api/ in URL
      final response = await http.post(
        Uri.parse('$baseUrl/api/groq/chat'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: json.encode({'prompt': prompt}),
      );

      final data = json.decode(response.body);

      if (response.statusCode == 200) {
        return GroqResponse(
          success: true,
          text: data['text'],
        );
      } else {
        return GroqResponse(
          success: false,
          error: data['error'] ?? 'Failed to get response',
          status: response.statusCode,
          retryAfter: data['retryAfter'],
        );
      }
    } catch (e) {
      return GroqResponse(
        success: false,
        error: "Network error. Please check your connection.",
        status: 0,
      );
    }
  }

  // ===== REAL-TIME WEBSOCKET METHODS =====
  
  // Initialize WebSocket connection for real-time updates
  Future<void> initializeRealTimeUpdates({String? adminId}) async {
    try {
      print('🔌 Initializing real-time WebSocket connection...');
      
      // Dispose existing socket if any
      if (_socket != null) {
        _socket!.disconnect();
        _socket = null;
      }
      
      // Create new socket connection
      _socket = IO.io(
        '$baseUrl/real-time-updates',
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .enableAutoConnect()
            .setReconnectionAttempts(5)
            .setReconnectionDelay(1000)
            .setTimeout(30000)
            .build(),
      );
      
      // Set up event listeners
      _setupSocketListeners(adminId: adminId);
      
      // Connect to the real-time updates namespace
      _socket!.connect();
      
      print('📱 WebSocket connection initiated');
    } catch (e) {
      print('❌ Error initializing WebSocket: $e');
    }
  }
  
  // Set up socket event listeners
  void _setupSocketListeners({String? adminId}) {
    if (_socket == null) return;
    
    // Connection event
    _socket!.onConnect((_) {
      print('✅ WebSocket connected successfully');
      _isConnected = true;
      
      // Join admin-specific room for targeted updates
      if (adminId != null && adminId.isNotEmpty) {
        _socket!.emit('join-admin-room', {'adminId': adminId});
        print('📱 Joined admin room: admin-$adminId');
      }
      
      // Test connection
      _socket!.emit('test-connection', {
        'adminId': adminId ?? 'default',
        'timestamp': DateTime.now().toIso8601String(),
      });
    });
    
    // Disconnection event
    _socket!.onDisconnect((_) {
      print('❌ WebSocket disconnected');
      _isConnected = false;
    });
    
    // Room join confirmation
    _socket!.on('room-joined', (data) {
      print('✅ Successfully joined room: $data');
    });
    
    // Test response
    _socket!.on('test-response', (data) {
      print('📡 Test response received: $data');
    });
    
    // Real-time dynamic updates
    _socket!.on('dynamic-update', (data) {
      print('🔄 Real-time update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // Admin-specific updates
    _socket!.on('admin-specific-update', (data) {
      print('🎯 Admin-specific update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // Splash screen updates
    _socket!.on('splash-screen', (data) {
      print('📱 Splash screen update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // Home page updates
    _socket!.on('home-page', (data) {
      print('🏠 Home page update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // App info updates
    _socket!.on('app-info', (data) {
      print('ℹ️ App info update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // Test updates
    _socket!.on('test-update', (data) {
      print('🧪 Test update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // Configuration updates
    _socket!.on('configuration-update', (data) {
      print('⚙️ Configuration update received: $data');
      _realTimeUpdateController.add(Map<String, dynamic>.from(data));
    });
    
    // Error handling
    _socket!.onConnectError((error) {
      print('❌ WebSocket connection error: $error');
      _isConnected = false;
    });
    
    _socket!.onError((error) {
      print('❌ WebSocket error: $error');
    });
  }
  
  // Disconnect WebSocket
  void disconnectRealTimeUpdates() {
    if (_socket != null) {
      print('🔌 Disconnecting WebSocket...');
      _socket!.disconnect();
      _socket = null;
      _isConnected = false;
    }
  }
  
  // Reconnect WebSocket
  Future<void> reconnectRealTimeUpdates({String? adminId}) async {
    disconnectRealTimeUpdates();
    await Future.delayed(Duration(seconds: 1));
    await initializeRealTimeUpdates(adminId: adminId);
  }
  
  // Check connection status
  bool isRealTimeConnected() {
    return _isConnected && _socket != null && _socket!.connected;
  }
  
  // Get current user/admin information
  Future<Map<String, dynamic>> getCurrentUser() async {
    try {
      // Get token from storage
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token');
      
      if (token == null) {
        return {
          'success': false,
          'error': 'No authentication token found'
        };
      }

      final response = await http.get(
        Uri.parse('$baseUrl/api/user/profile'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token'
        },
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        return {
          'success': false,
          'error': 'HTTP ${response.statusCode}: ${response.body}',
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('❌ Error getting current user: $e');
      return {
        'success': false,
        'error': e.toString()
      };
    }
  }

  // Test real-time connection
  Future<Map<String, dynamic>> testRealTimeConnection({
    required String adminId,
    String? appName,
    String? testMessage
  }) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/admin/test-update'),
        headers: {
          'Content-Type': 'application/json',
        },
        body: json.encode({
          'adminId': adminId,
          'appName': appName ?? 'TestApp',
          'testMessage': testMessage ?? 'Testing real-time connection'
        }),
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        print('📡 Test update sent successfully');
        return {
          'success': true,
          'data': data,
          'statusCode': response.statusCode,
        };
      } else {
        return {
          'success': false,
          'error': 'HTTP ${response.statusCode}: ${response.body}',
          'statusCode': response.statusCode,
        };
      }
    } catch (e) {
      print('❌ Error sending test update: $e');
      return {
        'success': false,
        'error': e.toString()
      };
    }
  }

  // Dispose resources
  void dispose() {
    disconnectRealTimeUpdates();
    _realTimeUpdateController.close();
  }

  // ===== END REAL-TIME WEBSOCKET METHODS =====
}