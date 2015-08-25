//
//  Speiseplan.swift
//  Emeal
//
//  Created by Kilian Költzsch on 18/08/15.
//  Copyright © 2015 Kilian Koeltzsch. All rights reserved.
//

import UIKit
import Alamofire
import Ji

/**
Errors specific to Speiseplan

- Request: Unable to get any response. Internet?
- Server: Server response isn't as expected
- UnknownCanteen: There's no info on the requested canteen
- OutdatedData: The requested data is old and should be refreshed
*/
enum SpeiseplanError: ErrorType {
	case Request
	case Server
	case UnknownCanteen
	case OutdatedData
}

class Speiseplan {

	var savedCanteens = [Canteen]()
	var savedMeals = [String: [Meal]]()
	var lastUpdated = NSDate()

	static let shared = Speiseplan()
	private init() {}

	func updateFromFeed(completion: (SpeiseplanError?) -> Void) {
		UIApplication.sharedApplication().networkActivityIndicatorVisible = true
		Alamofire.request(.GET, Constants.spFeedURL).responseData { [unowned self] (_, res, result) -> Void in
			defer { UIApplication.sharedApplication().networkActivityIndicatorVisible = false }
			guard let res = res else { completion(.Request); return }
			guard res.statusCode == 200 else { completion(.Server); return }
			guard let data = result.value else { completion(.Server); return }

			self.savedCanteens = [Canteen]()
			self.savedMeals = [String: [Meal]]()

			let jiDoc = Ji(xmlData: data)

			let dateFormatter = NSDateFormatter()
			// "Mon, 24 Aug 2015 13:52:33 +0200"
			dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss ZZZ"

			let items = jiDoc?.xPath("//item")
			for item in items! {
				if let title = item.xPath("title").first?.content, let author = item.xPath("author").first?.content, let link = item.xPath("link").first?.content {
					let canteen = Canteen(name: author, address: "", coords: (1.0, 1.0))
					let mealTitleElements = processTitle(title)
					let meal = Meal(id: processLinkToID(link), name: mealTitleElements.0, price: mealTitleElements.1, ingredients: [], allergens: [], imageURL: nil)

					if !self.savedCanteens.contains(canteen) {
						self.savedCanteens.append(canteen)
						self.savedMeals[canteen.name] = []
					}

					self.savedMeals[canteen.name]?.append(meal)
				}
			}

			completion(nil)
		}
	}

	func canteens() throws -> [Canteen] {
		guard NSDate().timeIntervalSinceDate(self.lastUpdated) < 60*30 else { throw SpeiseplanError.OutdatedData }
		return self.savedCanteens
	}

	func meals(forCanteen canteenName: String) throws -> [Meal] {
		guard NSDate().timeIntervalSinceDate(self.lastUpdated) < 60*30 else { throw SpeiseplanError.OutdatedData }
		guard let theseMeals = self.savedMeals[canteenName] else { throw SpeiseplanError.UnknownCanteen }
		return theseMeals
	}

	func mealDetails(var forMeal meal: Meal, completion: (SPResult<Meal, SpeiseplanError>) -> Void) {
		UIApplication.sharedApplication().networkActivityIndicatorVisible = true
		Alamofire.request(.GET, Constants.spDetailURL(meal.id)).responseData { (_, res, result) -> Void in
			defer { UIApplication.sharedApplication().networkActivityIndicatorVisible = false }
			guard let res = res else { completion(.Failure(.Request)); return }
			guard res.statusCode == 200 else { completion(.Failure(SpeiseplanError.Server)); return }
			guard let data = result.value else { completion(.Failure(SpeiseplanError.Server)); return }

			let jiDoc = Ji(htmlData: data)

			// Let's get the image
			if let mealImageURLComponent = jiDoc?.xPath("//a[@id='essenfoto']")?.first?["href"] {
				if let mealImageURL = NSURL(string: mealImageURLComponent, relativeToURL: NSURL(string: "https://bilderspeiseplan.studentenwerk-dresden.de")!) {
					meal.imageURL = mealImageURL
				}
			}

			// Now for the ingredients
			if let ingredientsList = jiDoc?.xPath("//div[@id='speiseplandetailsrechts']/ul[1]/li"), let title = jiDoc?.xPath("//div[@id='speiseplandetailsrechts']/h2[1]") {
				if title.first?.content == "Allgemeine Informationen zur Speise:" {
					for ingredient in ingredientsList {
						if let ing = Ingredient(rawValue: ingredient.content!) {
							meal.ingredients.append(ing)
						} else {
							NSLog("Unknown ingredient for meal \(meal.id): \(ingredient.content)")
						}
					}
				} else {
					NSLog("Meal \(meal.id) has no list of ingredients")
				}
			}

			// And the allergens
			if let allergensList = jiDoc?.xPath("//div[@id='speiseplandetailsrechts']/ul[2]/li"), let title = jiDoc?.xPath("//div[@id='speiseplandetailsrechts']/h2[2]") {
				if title.first?.content == "Infos zu enthaltenen Allergenen[2]:" {
					for allergen in allergensList {
						if let all = Allergen(rawValue: allergen.content!) {
							meal.allergens.append(all)
						} else {
							NSLog("Unknown allergen for meal \(meal.id): \(allergen.content)")
						}
					}
				} else {
					NSLog("Meal \(meal.id) has no list of allergens")
				}
			}

			// And the check if this is vegan or not, because that has to specified elsewhere and not where it belongs (┛ò__ó)┛彡┻━┻
			if let additionalInfos = jiDoc?.xPath("//div[@id='speiseplandetailsrechts']/ul[3]/li"), let title = jiDoc?.xPath("//div[@id='speiseplandetailsrechts']/h2[3]") {
				if title.first?.content == "Weitere Informationen:" {
					for info in additionalInfos {
						if let inf = Ingredient(rawValue: info.content!) {
							meal.ingredients.append(inf)
						} else {
							NSLog("Unknown additional info for meal \(meal.id): \(info.content)")
						}
					}
				} else {
					NSLog("Meal \(meal.id) has no list of additional information")
				}
			}

			completion(.Success(meal))
		}
	}
}

// MARK: - Helper functions

func processTitle(title: String) -> (String, PricePair?) {
	// FIXME: If something isn't available anymore the price is substituted with "(ausverkauft)"
	let titleElements = title.componentsSeparatedByString(" (")
	let name = titleElements[0]

	// If we get something without a price, don't stupidly try to do something with that data
	if titleElements.count == 2 {
		let priceElements = titleElements[1].componentsSeparatedByString("/")
		let skipChars = NSMutableCharacterSet()
		skipChars.formUnionWithCharacterSet(NSCharacterSet.letterCharacterSet())
		skipChars.formUnionWithCharacterSet(NSCharacterSet.punctuationCharacterSet())
		skipChars.formUnionWithCharacterSet(NSCharacterSet.whitespaceAndNewlineCharacterSet())

		if priceElements.count == 2 {
			let studentPrice = (priceElements[0].stringByTrimmingCharactersInSet(skipChars) as NSString).doubleValue
			let employeePrice = (priceElements[1].stringByTrimmingCharactersInSet(skipChars) as NSString).doubleValue
			return (name, (studentPrice, employeePrice))
		} else if priceElements.count == 1 {
			let price = (priceElements[0].stringByTrimmingCharactersInSet(skipChars) as NSString).doubleValue
			return (name, (price, nil))
		}
	}
	return (name, nil)
}

func processLinkToID(link: String) -> Int {
	let skipChars = NSMutableCharacterSet()
	skipChars.formUnionWithCharacterSet(NSCharacterSet.letterCharacterSet())
	skipChars.formUnionWithCharacterSet(NSCharacterSet.punctuationCharacterSet())
	return (link.stringByTrimmingCharactersInSet(skipChars) as NSString).integerValue
}
